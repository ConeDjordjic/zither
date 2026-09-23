const std = @import("std");
const Io = std.Io;
const net = Io.net;
const martensite = @import("martensite");
const Server = martensite.Server;
const Status = martensite.Status;
const Response = martensite.Response;

const router = @import("router.zig");
const stop_mod = @import("stop.zig");
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
    /// The biggest body `readJson` accepts. A bigger one gets a 413.
    max_body: u64 = 1024 * 1024,
    /// Leaves `Secure` off every cookie, for local development over
    /// plain HTTP.
    insecure_cookies: bool = false,
    /// How long `run` waits for requests in progress once it is stopped.
    grace: Io.Clock.Duration = seconds(10),
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
        error.BadQuery, error.BadJson => .bad_request,
        error.NotJson => .unsupported_media_type,
        else => .forError(err),
    };
}

/// Shared by `run` and its connections while it stops.
const Drain = struct {
    draining: std.atomic.Value(bool) = .init(false),
    /// Connections inside a handler.
    busy: std.atomic.Value(usize) = .init(0),

    /// Waits until no handler is running, or `grace` is up.
    fn wait(drain: *Drain, io: Io, grace: Io.Clock.Duration) Io.Cancelable!void {
        const until = (Io.Timeout{ .duration = grace }).toDeadline(io);
        while (drain.busy.load(.seq_cst) != 0) {
            if (until.toDurationFromNow(io).?.raw.nanoseconds <= 0) return;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
    }
};

pub fn App(comptime State: type, comptime routes: []const Route(State)) type {
    const Table = router.Table(Handler(State), routes);

    return struct {
        pub const Context = Ctx(State);

        /// Accepts connections and serves each one on its own task.
        /// `gpa` is used from all of them at once, so it has to be
        /// thread-safe.
        ///
        /// `stop` or `stopOnSignals` make it stop accepting. Requests in
        /// progress get `grace` to finish, and their responses say
        /// `Connection: close`. Then every connection left is cut off,
        /// and it returns. Canceling it cuts everything off right away.
        pub fn run(io: Io, gpa: std.mem.Allocator, listener: *net.Server, state: *State, options: Options) Io.Cancelable!void {
            var group: Io.Group = .init;
            defer group.cancel(io);
            var drain: Drain = .{};

            while (true) {
                const stream = listener.accept(io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.SocketNotListening => {
                        drain.draining.store(true, .seq_cst);
                        // The connections left are between requests. One
                        // that sends a request right now gets cut off.
                        return drain.wait(io, options.grace);
                    },
                    else => {
                        log.warn("accept: {t}", .{err});
                        continue;
                    },
                };
                group.async(io, serveDraining, .{ io, gpa, stream, state, options, &drain });
            }
        }

        /// Serves one connection until it ends, and closes it.
        pub fn serveStream(io: Io, gpa: std.mem.Allocator, stream: net.Stream, state: *State, options: Options) Io.Cancelable!void {
            return serveDraining(io, gpa, stream, state, options, null);
        }

        fn serveDraining(io: Io, gpa: std.mem.Allocator, stream: net.Stream, state: *State, options: Options, drain: ?*Drain) Io.Cancelable!void {
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

            var dispatch: Dispatch = .{ .state = state, .io = io, .arena = &arena, .options = &options, .drain = drain };
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
            drain: ?*Drain = null,

            pub fn handle(d: *Dispatch, http: *Server, req: Server.Request) !void {
                const drain = d.drain orelse return d.route(http, req);
                _ = drain.busy.fetchAdd(1, .seq_cst);
                defer _ = drain.busy.fetchSub(1, .seq_cst);
                // Before, so the response says Connection: close. After,
                // for a request that was already running when `run` was
                // stopped.
                if (drain.draining.load(.seq_cst)) http.keep_alive = false;
                defer if (drain.draining.load(.seq_cst)) {
                    http.keep_alive = false;
                };
                return d.route(http, req);
            }

            fn route(d: *Dispatch, http: *Server, req: Server.Request) !void {
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
                            .max_body = d.options.max_body,
                            .insecure_cookies = d.options.insecure_cookies,
                            .draining = if (d.drain) |drain| &drain.draining else null,
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
    .post("/login", login),
    .get("/me", me),
    .post("/half", half),
});

fn login(c: *TestCtx) !void {
    const In = struct { name: []const u8 };
    const in = try c.readJson(In);
    try c.setCookie(.{ .name = "sid", .value = in.name, .max_age = 60 });
    try c.json(.ok, .{ .hello = in.name });
}

fn me(c: *TestCtx) !void {
    try c.clearCookie("old");
    try c.header("X-Seen", "yes");
    try c.respond(.text(.ok, c.cookie("sid") orelse "nobody"));
}

/// Sets a cookie and then fails, so the cookie must not go out.
fn half(c: *TestCtx) !void {
    try c.setCookie(.{ .name = "sid", .value = "leaked" });
    return error.DatabaseDown;
}

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

test "readJson parses the body and setCookie goes out with json" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const body = "{\"name\":\"ana\",\"extra\":1}";
    const got = exchange(&state, .{}, "POST /login HTTP/1.1\r\nHost: x\r\nContent-Type: application/json; charset=utf-8\r\n" ++
        std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{body.len}) ++ body, &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 "));
    try testing.expect(has(got, "Content-Type: application/json\r\n"));
    try testing.expect(has(got, "Set-Cookie: sid=ana; Path=/; Max-Age=60; HttpOnly; Secure; SameSite=Lax\r\n"));
    try testing.expect(std.mem.endsWith(u8, got, "\r\n\r\n{\"hello\":\"ana\"}"));
}

test "insecure_cookies leaves out Secure" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{ .insecure_cookies = true }, "POST /login HTTP/1.1\r\nHost: x\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 12\r\n\r\n{\"name\":\"a\"}", &out);
    try testing.expect(has(got, "Set-Cookie: sid=a; Path=/; Max-Age=60; HttpOnly; SameSite=Lax\r\n"));
}

test "a chunked JSON body" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "POST /login HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n6\r\n{\"name\r\n6\r\n\":\"b\"}\r\n0\r\n\r\n", &out);
    try testing.expect(std.mem.endsWith(u8, got, "{\"hello\":\"b\"}"));
}

test "bad JSON is a 400 and the connection stays" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "POST /login HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n" ++
        "Content-Length: 3\r\n\r\n{no" ++ "GET /me HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 400 "));
    try testing.expect(std.mem.endsWith(u8, got, "nobody"));
}

test "JSON of the wrong shape and no body are both a 400" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    var got = exchange(&state, .{}, "POST /login HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n" ++
        "Content-Length: 10\r\n\r\n{\"name\":1}", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 400 "));
    got = exchange(&state, .{}, "POST /login HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 400 "));
}

test "a body that isn't application/json is a 415" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    for ([_][]const u8{ "Content-Type: text/plain\r\n", "" }) |ct| {
        var input: [256]u8 = undefined;
        const req = try std.fmt.bufPrint(&input, "POST /login HTTP/1.1\r\nHost: x\r\n{s}Content-Length: 12\r\n\r\n{{\"name\":\"a\"}}", .{ct});
        const got = exchange(&state, .{}, req, &out);
        try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 415 "));
    }
}

test "a body over max_body is a 413" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{ .max_body = 4 }, "POST /login HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n" ++
        "Content-Length: 12\r\n\r\n{\"name\":\"a\"}", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 413 "));
}

test "cookies are read across Cookie headers, and headers are collected" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{}, "GET /me HTTP/1.1\r\nHost: x\r\nCookie: a=1\r\nCookie: sid=\"ana\"\r\n\r\n", &out);
    try testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nana"));
    try testing.expect(has(got, "Set-Cookie: old=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax\r\n"));
    try testing.expect(has(got, "X-Seen: yes\r\n"));
}

test "a refusal drops the collected headers" {
    var state: TestState = .{};
    var out: [1024]u8 = undefined;
    const got = exchange(&state, .{ .log_error = remember }, "POST /half HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 500 "));
    try testing.expect(!has(got, "Set-Cookie"));
}

const SlowState = struct {
    entered: std.atomic.Value(bool) = .init(false),
};

fn slow(c: *Ctx(SlowState)) !void {
    c.state.entered.store(true, .seq_cst);
    try c.io.sleep(.fromMilliseconds(200), .awake);
    try c.respond(.text(.ok, "done"));
}

test "stopping lets a request in progress finish and closes the idle ones" {
    const io = testing.io;
    const Slow = App(SlowState, &.{.get("/slow", slow)});

    const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var state: SlowState = .{};
    var running = try io.concurrent(Slow.run, .{ io, testing.allocator, &listener, &state, .{} });

    const busy = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer busy.close(io);
    const idle = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer idle.close(io);

    var wbuf: [64]u8 = undefined;
    var w = busy.writer(io, &wbuf);
    try w.interface.writeAll("GET /slow HTTP/1.1\r\nHost: x\r\n\r\n");
    try w.interface.flush();
    while (!state.entered.load(.seq_cst)) try io.sleep(.fromMilliseconds(1), .awake);

    stop_mod.stop(io, &listener);
    try running.await(io);

    var rbuf: [512]u8 = undefined;
    var r = busy.reader(io, &rbuf);
    const got = try r.interface.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 "));
    try testing.expect(has(got, "Connection: close\r\n"));
    try testing.expect(std.mem.endsWith(u8, got, "done"));

    var ir = idle.reader(io, &rbuf);
    const rest = try ir.interface.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(rest);
    try testing.expectEqualStrings("", rest);
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
