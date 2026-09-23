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
});

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("listening on :8080\n", .{});

    var state: State = .{ .greeting = "hello" };
    try App.run(io, init.gpa, &listener, &state, .{});
}

fn index(c: *Ctx) !void {
    try c.respond(.text(.ok, "try /hello/you or /search?q=something\n"));
}

fn hello(c: *Ctx) !void {
    const text = try std.fmt.allocPrint(c.arena, "{s} {s}\n", .{ c.state.greeting, c.param("name").? });
    try c.respond(.text(.ok, text));
}

fn search(c: *Ctx) !void {
    const q = try c.query("q") orelse return c.respond(.text(.bad_request, "no q\n"));
    const text = try std.fmt.allocPrint(c.arena, "you searched for {s}\n", .{q});
    try c.respond(.text(.ok, text));
}
