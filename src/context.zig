const std = @import("std");
const martensite = @import("martensite");
const Server = martensite.Server;

const percent = @import("percent.zig");

pub const Params = struct {
    names: []const []const u8 = &.{},
    /// Percent-decoded.
    values: []const []const u8 = &.{},

    pub fn get(p: Params, name: []const u8) ?[]const u8 {
        for (p.names, p.values) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }
};

pub const QueryError = error{
    /// The value has a `%` without two hex digits after it. zither
    /// answers it with a 400 and keeps the connection.
    BadQuery,
} || std.mem.Allocator.Error;

/// What a handler gets for one request.
pub fn Ctx(comptime State: type) type {
    return struct {
        /// Every connection has the same one at the same time, so
        /// anything in it that changes needs a lock.
        state: *State,
        io: std.Io,
        /// Reset before the next request on the connection.
        arena: std.mem.Allocator,
        http: *Server,
        req: Server.Request,
        params: Params,

        const C = @This();

        pub fn param(c: *const C, name: []const u8) ?[]const u8 {
            return c.params.get(name);
        }

        /// The first value for `name` in the query, decoded into the
        /// arena. `name` is plain, not encoded. A name that appears with
        /// no `=` gives an empty value.
        pub fn query(c: *const C, name: []const u8) QueryError!?[]const u8 {
            var pairs: martensite.target.Pairs = .init(c.req.parsedTarget().query);
            while (pairs.next()) |p| {
                if (!percent.eql(p.name, name, true)) continue;
                const out = try c.arena.alloc(u8, p.value.len);
                return martensite.target.decodeQuery(p.value, out) catch |err| switch (err) {
                    error.BadEscape => error.BadQuery,
                    // Decoding never makes the value longer.
                    error.NoSpace => unreachable,
                };
            }
            return null;
        }

        pub fn respond(c: *const C, r: martensite.Response) Server.SendError!void {
            return c.http.respond(r);
        }
    };
}

test "params by name" {
    const p: Params = .{ .names = &.{ "id", "slug" }, .values = &.{ "42", "sarma" } };
    try std.testing.expectEqualStrings("sarma", p.get("slug").?);
    try std.testing.expectEqual(@as(?[]const u8, null), p.get("nope"));
}
