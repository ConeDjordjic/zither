//! Reading the Cookie header and writing Set-Cookie (RFC 6265).

const std = @import("std");

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    path: ?[]const u8 = "/",
    domain: ?[]const u8 = null,
    /// Seconds. Null makes it a session cookie, gone when the browser
    /// closes. 0 deletes it.
    max_age: ?u32 = null,
    http_only: bool = true,
    secure: bool = true,
    same_site: ?SameSite = .lax,

    pub const SameSite = enum { strict, lax, none };
};

pub const Error = error{
    /// A name that isn't a token, a value with bytes RFC 6265 doesn't
    /// allow, or a path or domain with a `;` or a control byte.
    InvalidCookie,
};

/// The value of the first cookie called `name` in one Cookie header,
/// without surrounding quotes.
pub fn get(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (!std.mem.eql(u8, trimmed[0..eq], name)) continue;
        const value = trimmed[eq + 1 ..];
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
        return value;
    }
    return null;
}

/// The Set-Cookie value for `c`. With `insecure` it leaves out `Secure`,
/// for local development over plain HTTP.
pub fn format(allocator: std.mem.Allocator, c: Cookie, insecure: bool) (Error || std.mem.Allocator.Error)![]const u8 {
    try check(c);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    formatTo(w, c, insecure) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn formatTo(w: *std.Io.Writer, c: Cookie, insecure: bool) std.Io.Writer.Error!void {
    try w.print("{s}={s}", .{ c.name, c.value });
    if (c.path) |p| try w.print("; Path={s}", .{p});
    if (c.domain) |d| try w.print("; Domain={s}", .{d});
    if (c.max_age) |n| try w.print("; Max-Age={d}", .{n});
    if (c.http_only) try w.writeAll("; HttpOnly");
    if (c.secure and !insecure) try w.writeAll("; Secure");
    if (c.same_site) |s| try w.writeAll(switch (s) {
        .strict => "; SameSite=Strict",
        .lax => "; SameSite=Lax",
        .none => "; SameSite=None",
    });
}

fn check(c: Cookie) Error!void {
    if (c.name.len == 0) return error.InvalidCookie;
    for (c.name) |b| if (!isTchar(b)) return error.InvalidCookie;

    var value = c.value;
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    for (value) |b| if (!isCookieOctet(b)) return error.InvalidCookie;

    for ([_]?[]const u8{ c.path, c.domain }) |attr| {
        for (attr orelse continue) |b| {
            if (b < 0x20 or b == 0x7f or b == ';') return error.InvalidCookie;
        }
    }
}

fn isTchar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", b) != null;
}

/// US-ASCII without controls, whitespace, `"`, `,`, `;` and `\`.
fn isCookieOctet(b: u8) bool {
    return switch (b) {
        0x21, 0x23...0x2b, 0x2d...0x3a, 0x3c...0x5b, 0x5d...0x7e => true,
        else => false,
    };
}

const testing = std.testing;

test "finds a cookie among others" {
    try testing.expectEqualStrings("abc", get("a=1; sid=abc; b=2", "sid").?);
    try testing.expectEqualStrings("abc", get("sid=abc", "sid").?);
}

test "absent is null, and a prefix is not a match" {
    try testing.expectEqual(@as(?[]const u8, null), get("a=1; b=2", "sid"));
    try testing.expectEqual(@as(?[]const u8, null), get("sidx=abc", "sid"));
}

test "an empty value is a value" {
    try testing.expectEqualStrings("", get("sid=", "sid").?);
}

test "surrounding quotes are stripped" {
    try testing.expectEqualStrings("abc", get("sid=\"abc\"", "sid").?);
    try testing.expectEqualStrings("\"", get("sid=\"", "sid").?);
}

test "the defaults are the safe ones" {
    const got = try format(testing.allocator, .{ .name = "sid", .value = "abc" }, false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("sid=abc; Path=/; HttpOnly; Secure; SameSite=Lax", got);
}

test "insecure leaves out Secure" {
    const got = try format(testing.allocator, .{ .name = "sid", .value = "abc", .max_age = 60 }, true);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("sid=abc; Path=/; Max-Age=60; HttpOnly; SameSite=Lax", got);
}

test "every attribute can be turned off" {
    const got = try format(testing.allocator, .{
        .name = "theme",
        .value = "dark",
        .path = null,
        .http_only = false,
        .secure = false,
        .same_site = null,
    }, false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("theme=dark", got);
}

test "a domain and strict" {
    const got = try format(testing.allocator, .{
        .name = "a",
        .value = "\"quoted\"",
        .domain = "example.com",
        .same_site = .strict,
    }, false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a=\"quoted\"; Path=/; Domain=example.com; HttpOnly; Secure; SameSite=Strict", got);
}

test "bytes that would break the header are refused" {
    const bad = [_]Cookie{
        .{ .name = "", .value = "x" },
        .{ .name = "a b", .value = "x" },
        .{ .name = "a=b", .value = "x" },
        .{ .name = "a", .value = "x; Domain=evil.com" },
        .{ .name = "a", .value = "x y" },
        .{ .name = "a", .value = "x,y" },
        .{ .name = "a", .value = "x\r\ny" },
        .{ .name = "a", .value = "x", .path = "/; Domain=evil.com" },
        .{ .name = "a", .value = "x", .domain = "a\nb" },
    };
    for (bad) |c| try testing.expectError(error.InvalidCookie, format(testing.allocator, c, false));
}
