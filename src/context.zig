const std = @import("std");
const martensite = @import("martensite");
const Server = martensite.Server;
const Response = martensite.Response;

const percent = @import("percent.zig");
const cookie_mod = @import("cookie.zig");

pub const Cookie = cookie_mod.Cookie;

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

pub const ReadJsonError = error{
    /// No body, a body that isn't JSON, or JSON that doesn't fit the
    /// type. zither answers it with a 400.
    BadJson,
    /// The Content-Type isn't `application/json`. zither answers it with
    /// a 415.
    NotJson,
} || Server.ReadBodyError || std.mem.Allocator.Error;

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
        max_body: u64,
        insecure_cookies: bool,
        /// What `header` and `setCookie` collected for the response.
        extra: std.ArrayList(Response.Header) = .empty,

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

        /// The first cookie called `name`, across every Cookie header,
        /// without surrounding quotes. Nothing is decoded.
        pub fn cookie(c: *const C, name: []const u8) ?[]const u8 {
            var it = c.req.headerIter("cookie");
            while (it.next()) |h| {
                if (cookie_mod.get(h, name)) |v| return v;
            }
            return null;
        }

        /// Reads the body and parses it into a `T` in the arena. Fields
        /// that `T` doesn't have are skipped.
        pub fn readJson(c: *C, comptime T: type) ReadJsonError!T {
            if (!c.req.hasBody()) return error.BadJson;
            const ct = c.req.header("content-type") orelse return error.NotJson;
            const media = std.mem.trim(u8, ct[0 .. std.mem.indexOfScalar(u8, ct, ';') orelse ct.len], " \t");
            if (!std.ascii.eqlIgnoreCase(media, "application/json")) return error.NotJson;

            // A chunked body doesn't say how long it is, so it gets the
            // whole limit.
            const n = c.req.contentLength() orelse c.max_body;
            if (n > c.max_body) return error.BodyTooLarge;
            const raw = try c.http.readBody(try c.arena.alloc(u8, @intCast(n)));

            return std.json.parseFromSliceLeaky(T, c.arena, raw, .{
                .ignore_unknown_fields = true,
            }) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.BadJson,
            };
        }

        /// Adds a header to the response `respond` or `json` sends.
        /// `name` and `value` have to stay valid until then.
        pub fn header(c: *C, name: []const u8, value: []const u8) std.mem.Allocator.Error!void {
            try c.extra.append(c.arena, .{ .name = name, .value = value });
        }

        pub fn setCookie(c: *C, cookie_: Cookie) (cookie_mod.Error || std.mem.Allocator.Error)!void {
            const value = try cookie_mod.format(c.arena, cookie_, c.insecure_cookies);
            try c.header("Set-Cookie", value);
        }

        /// Deletes a cookie that was set with the default path. For any
        /// other path, use `setCookie` with the same path and
        /// `.max_age = 0`.
        pub fn clearCookie(c: *C, name: []const u8) (cookie_mod.Error || std.mem.Allocator.Error)!void {
            try c.setCookie(.{ .name = name, .value = "", .max_age = 0 });
        }

        /// Sends `r` with the headers from `header` and `setCookie`
        /// after its own.
        pub fn respond(c: *C, r: Response) (Server.SendError || std.mem.Allocator.Error)!void {
            var out = r;
            if (c.extra.items.len != 0) {
                const all = try c.arena.alloc(Response.Header, r.headers.len + c.extra.items.len);
                @memcpy(all[0..r.headers.len], r.headers);
                @memcpy(all[r.headers.len..], c.extra.items);
                out.headers = all;
            }
            return c.http.respond(out);
        }

        pub fn json(c: *C, status: martensite.Status, value: anytype) (Server.SendError || std.mem.Allocator.Error)!void {
            const body = try std.json.Stringify.valueAlloc(c.arena, value, .{});
            return c.respond(.json(status, body));
        }
    };
}

test "params by name" {
    const p: Params = .{ .names = &.{ "id", "slug" }, .values = &.{ "42", "sarma" } };
    try std.testing.expectEqualStrings("sarma", p.get("slug").?);
    try std.testing.expectEqual(@as(?[]const u8, null), p.get("nope"));
}
