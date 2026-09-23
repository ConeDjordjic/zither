const std = @import("std");
const Io = std.Io;
const net = Io.net;
const martensite = @import("martensite");
const Server = martensite.Server;
const Status = martensite.Status;
const Response = martensite.Response;

const router = @import("router.zig");
const context = @import("context.zig");
const Ctx = context.Ctx;

const log = std.log.scoped(.zither);

pub fn Handler(comptime State: type) type {
    return *const fn (*Ctx(State)) anyerror!void;
}

pub fn Route(comptime State: type) type {
    return router.Route(Handler(State));
}

pub const Options = struct {
    /// The response for anything zither answers itself: 404, 405, 501,
    /// a request that couldn't be read, a param that doesn't decode,
    /// and errors out of handlers. zither sets the status and adds
    /// `Allow` to a 405, so you only choose the body.
    refuse: *const fn (Status) Response = plain,
    /// Called for a handler error that became a 5xx. By default it goes
    /// to `std.log` at error level.
    log_error: *const fn (Server.Request, anyerror) void = logError,
    /// A single read. A peer that sends nothing for this long is gone.
    read: Io.Clock.Duration = seconds(5),
    /// Waiting for the next request and reading its head.
    head: Io.Clock.Duration = seconds(10),
    /// The handler's time, reading the body included.
    body: Io.Clock.Duration = seconds(30),
    /// Each connection gets three of these, to read, write and hold the
    /// head while the body is read. A head has to fit in one.
    buffer: usize = 16 * 1024,
    headers: usize = 64,
    /// How much of a body a handler didn't read gets thrown away to keep
    /// the connection. See martensite's `Server.Options.max_drain`.
    max_drain: u64 = 64 * 1024,
    /// Arena memory a connection keeps between requests.
    arena_keep: usize = 64 * 1024,
};

fn plain(status: Status) Response {
    return .text(status, status.phrase());
}

fn logError(req: Server.Request, err: anyerror) void {
    log.err("{s} {s}: {t}", .{ req.method(), req.target(), err });
}

fn seconds(n: i64) Io.Clock.Duration {
    return .{ .raw = .fromSeconds(n), .clock = .awake };
}

/// A handler's own error is a 500, like in martensite, unless it is one
/// zither gave it.
fn statusFor(err: anyerror) Status {
    return switch (err) {
        error.BadQuery => .bad_request,
        else => .forError(err),
    };
}

pub fn App(comptime State: type, comptime routes: []const Route(State)) type {
    const Table = router.Table(Handler(State), routes);

    return struct {
        pub const Context = Ctx(State);

        /// Accepts connections until the listener is shut down, and
        /// serves each one on its own task. `gpa` is used from all of
        /// them at once, so it has to be thread-safe.
        pub fn run(io: Io, gpa: std.mem.Allocator, listener: *net.Server, state: *State, options: Options) Io.Cancelable!void {
            var group: Io.Group = .init;
            defer group.cancel(io);

            while (true) {
                const stream = listener.accept(io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.SocketNotListening => return,
                    else => {
                        log.warn("accept: {t}", .{err});
                        continue;
                    },
                };
                group.async(io, serveStream, .{ io, gpa, stream, state, options });
            }
        }

        /// Serves one connection until it ends, and closes it.
        pub fn serveStream(io: Io, gpa: std.mem.Allocator, stream: net.Stream, state: *State, options: Options) Io.Cancelable!void {
            defer stream.close(io);

            const bufs = gpa.alloc(u8, 3 * options.buffer) catch return;
            defer gpa.free(bufs);
            const headers = gpa.alloc(martensite.Header, options.headers) catch return;
            defer gpa.free(headers);
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();

            const n = options.buffer;
            var reader: martensite.TimedReader = .init(io, stream, bufs[0..n], .{ .duration = options.read });
            var writer = stream.writer(io, bufs[n .. 2 * n]);
            // Only fails when head_buf is smaller than the read buffer.
            var http = Server.init(io, &reader.interface, &writer.interface, .{
                .headers = headers,
                .head_buf = bufs[2 * n ..],
                .max_drain = options.max_drain,
                .failure = reader.failureSource(),
            }) catch unreachable;

            var dispatch: Dispatch = .{ .state = state, .io = io, .arena = &arena, .options = &options };
            http.serve(&dispatch, .{
                .deadline = reader.deadlines(),
                .head = .{ .duration = options.head },
                .body = .{ .duration = options.body },
            }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                // The peer already got whatever it was owed.
                else => return,
            };
        }

        /// The handler martensite's `serve` calls. Use it if you want a
        /// connection loop of your own.
        pub const Dispatch = struct {
            state: *State,
            io: Io,
            arena: *std.heap.ArenaAllocator,
            options: *const Options,

            pub fn handle(d: *Dispatch, http: *Server, req: Server.Request) !void {
                _ = d.arena.reset(.{ .retain_with_limit = d.options.arena_keep });
                const arena = d.arena.allocator();

                const method = req.knownMethod() orelse return d.refuse(http, .not_implemented, &.{});
                var raw: [Table.max_params][]const u8 = undefined;
                switch (Table.match(method, req.parsedTarget().path, &raw)) {
                    .not_found => return d.refuse(http, .not_found, &.{}),
                    .wrong_method => |allowed| {
                        var buf: [64]u8 = undefined;
                        return d.refuse(http, .method_not_allowed, &.{
                            .{ .name = "Allow", .value = allowList(allowed, &buf) },
                        });
                    },
                    .found => |found| {
                        const names = found.names;
                        var values: [Table.max_params][]const u8 = undefined;
                        for (raw[0..names.len], values[0..names.len]) |r, *v| {
                            const out = try arena.alloc(u8, r.len);
                            v.* = martensite.target.decode(r, out) catch
                                return d.refuse(http, .bad_request, &.{});
                        }
                        var c: Context = .{
                            .state = d.state,
                            .io = d.io,
                            .arena = arena,
                            .http = http,
                            .req = req,
                            .params = .{ .names = names, .values = values[0..names.len] },
                        };
                        return found.handler(&c);
                    },
                }
            }

            pub fn onError(d: *Dispatch, http: *Server, req: Server.Request, err: anyerror) !void {
                const status = statusFor(err);
                if (@intFromEnum(status) >= 500) d.options.log_error(req, err);
                try d.refuse(http, status, &.{});
            }

            pub fn onReceiveError(d: *Dispatch, http: *Server, err: anyerror) !void {
                try d.refuse(http, statusFor(err), &.{});
            }

            fn refuse(d: *Dispatch, http: *Server, status: Status, extra: []const Response.Header) !void {
                var r = d.options.refuse(status);
                r.status = status;
                if (extra.len != 0) {
                    const all = try d.arena.allocator().alloc(Response.Header, r.headers.len + extra.len);
                    @memcpy(all[0..r.headers.len], r.headers);
                    @memcpy(all[r.headers.len..], extra);
                    r.headers = all;
                }
                try http.respond(r);
            }
        };
    };
}

/// Every method name with ", " between them is under 64 bytes.
fn allowList(allowed: std.EnumSet(martensite.Method), buf: *[64]u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    var it = allowed.iterator();
    var first = true;
    while (it.next()) |m| {
        if (!first) w.writeAll(", ") catch unreachable;
        w.writeAll(@tagName(m)) catch unreachable;
        first = false;
    }
    return w.buffered();
}

const testing = std.testing;

const TestState = struct { hits: usize = 0 };
const TestCtx = Ctx(TestState);

const TestApp = App(TestState, &.{
    .get("/hello/:name", hello),
    .get("/search", search),
    .post("/items", create),
    .get("/boom", boom),
});

fn hello(c: *TestCtx) !void {
    c.state.hits += 1;
    const text = try std.fmt.allocPrint(c.arena, "hello {s}", .{c.param("name").?});
    try c.respond(.text(.ok, text));
}

fn search(c: *TestCtx) !void {
    const q = try c.query("q") orelse "nothing";
    try c.respond(.text(.ok, q));
}

fn create(c: *TestCtx) !void {
    try c.respond(.{ .status = .created });
}

fn boom(_: *TestCtx) !void {
    return error.DatabaseDown;
}

fn jsonRefusal(status: Status) Response {
    var r: Response = .json(status, "{\"error\":true}");
    r.headers = &.{.{ .name = "X-Kind", .value = "refusal" }};
    return r;
}

var remembered: ?anyerror = null;

fn remember(_: Server.Request, err: anyerror) void {
    remembered = err;
}

/// Runs `input` through the app and gives back what went out.
fn exchange(state: *TestState, options: Options, input: []const u8, out: []u8) []const u8 {
    var reader: Io.Reader = .fixed(input);
    var writer: Io.Writer = .fixed(out);
    var headers: [16]martensite.Header = undefined;
    var head_buf: [4096]u8 = undefined;
    var http = Server.init(testing.io, &reader, &writer, .{
        .headers = &headers,
        .head_buf = &head_buf,
        .date = false,
    }) catch unreachable;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: TestApp.Dispatch = .{ .state = state, .io = testing.io, .arena = &arena, .options = &options };
    http.serve(&d, .{}) catch {};
    return writer.buffered();
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "a route gets its decoded params and the state" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "GET /hello/a%20b HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 "));
    try testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nhello a b"));
    try testing.expectEqual(@as(usize, 1), state.hits);
}

test "HEAD runs the GET route and sends no body" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "HEAD /hello/x HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 "));
    try testing.expect(std.mem.endsWith(u8, got, "\r\n\r\n"));
    try testing.expectEqual(@as(usize, 1), state.hits);
}

test "an unknown path is a 404" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 404 "));
}

test "a wrong method is a 405 with Allow" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "DELETE /hello/x HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 405 "));
    try testing.expect(has(got, "Allow: GET, HEAD\r\n"));
}

test "a method with no name is a 501" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "BREW /hello/x HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 501 "));
}

test "a param that doesn't decode is a 400 and the connection stays" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "GET /hello/%zz HTTP/1.1\r\nHost: x\r\n\r\n" ++
        "GET /hello/x HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 400 "));
    try testing.expect(std.mem.endsWith(u8, got, "hello x"));
}

test "query values are decoded" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "GET /search?x=1&q=sarma+i%20pita HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nsarma i pita"));
}

test "a bad query value is a 400 and the connection stays" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "GET /search?q=%zz HTTP/1.1\r\nHost: x\r\n\r\n" ++
        "GET /search HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 400 "));
    try testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nnothing"));
}

test "a handler error is a 500 from the refusal" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{ .refuse = jsonRefusal, .log_error = remember }, "GET /boom HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 500 "));
    try testing.expect(has(got, "X-Kind: refusal\r\n"));
    try testing.expect(std.mem.endsWith(u8, got, "{\"error\":true}"));
    try testing.expectEqual(error.DatabaseDown, remembered.?);
}

test "a 405 keeps the refusal's headers and adds Allow" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{ .refuse = jsonRefusal }, "GET /items HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 405 "));
    try testing.expect(has(got, "X-Kind: refusal\r\n"));
    try testing.expect(has(got, "Allow: POST\r\n"));
}

test "a request that can't be read gets the refusal" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{ .refuse = jsonRefusal }, "GET /hello/x HTTP/1.1\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 400 "));
    try testing.expect(std.mem.endsWith(u8, got, "{\"error\":true}"));
}

test "allow lists methods in a fixed order" {
    var set: std.EnumSet(martensite.Method) = .initEmpty();
    set.insert(.POST);
    set.insert(.GET);
    set.insert(.HEAD);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("GET, HEAD, POST", allowList(set, &buf));
    try testing.expectEqualStrings(
        "GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH",
        allowList(.initFull(), &buf),
    );
}
