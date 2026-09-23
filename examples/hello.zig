const std = @import("std");
const zither = @import("zither");

const State = struct {
    greeting: []const u8,
};

const Ctx = zither.Ctx(State);

const App = zither.App(State, &.{
    .get("/", index),
    .get("/hello/:name", hello),
    .get("/search", search),
    .post("/name", setName),
});

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("listening on :8080\n", .{});

    // Ctrl-C lets requests in progress finish before it exits.
    zither.stopOnSignals(&listener);

    var state: State = .{ .greeting = "hello" };
    try App.run(io, init.gpa, &listener, &state, .{});
    std.debug.print("stopped\n", .{});
}

fn index(c: *Ctx) !void {
    try c.respond(.text(.ok, "try /hello/you or /search?q=something\n"));
}

fn hello(c: *Ctx) !void {
    const seen = c.cookie("name") orelse "stranger";
    const text = try std.fmt.allocPrint(c.arena, "{s} {s}, last time you were {s}\n", .{ c.state.greeting, c.param("name").?, seen });
    try c.respond(.text(.ok, text));
}

fn search(c: *Ctx) !void {
    const q = try c.query("q") orelse return c.respond(.text(.bad_request, "no q\n"));
    const text = try std.fmt.allocPrint(c.arena, "you searched for {s}\n", .{q});
    try c.respond(.text(.ok, text));
}

fn setName(c: *Ctx) !void {
    const in = try c.readJson(struct { name: []const u8 });
    // Plain HTTP here, so no Secure.
    try c.setCookie(.{ .name = "name", .value = in.name, .secure = false });
    try c.json(.ok, .{ .remembered = in.name });
}
