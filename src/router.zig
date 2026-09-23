//! Matching a method and a path against a route table that is fixed at
//! compile time.
//!
//! A segment that starts with `:` matches any one segment and captures
//! it. Empty segments are skipped, so `/a/` and `//a` both match `/a`.
//! When two routes match, the one with a literal segment where the
//! other has a param wins, compared from the left. So `/recipes/new`
//! beats `/recipes/:slug` whatever order they are listed in.

const std = @import("std");
const martensite = @import("martensite");
const Method = martensite.Method;

const percent = @import("percent.zig");

pub fn Route(comptime Handler: type) type {
    return struct {
        method: Method,
        pattern: []const u8,
        handler: Handler,

        const R = @This();

        pub fn on(method: Method, pattern: []const u8, handler: Handler) R {
            return .{ .method = method, .pattern = pattern, .handler = handler };
        }

        pub fn get(pattern: []const u8, handler: Handler) R {
            return .on(.GET, pattern, handler);
        }

        pub fn post(pattern: []const u8, handler: Handler) R {
            return .on(.POST, pattern, handler);
        }

        pub fn put(pattern: []const u8, handler: Handler) R {
            return .on(.PUT, pattern, handler);
        }

        pub fn patch(pattern: []const u8, handler: Handler) R {
            return .on(.PATCH, pattern, handler);
        }

        pub fn delete(pattern: []const u8, handler: Handler) R {
            return .on(.DELETE, pattern, handler);
        }
    };
}

const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
};

pub fn Match(comptime Handler: type) type {
    return union(enum) {
        found: struct {
            handler: Handler,
            /// Param names in the order they appear in the pattern. The
            /// values are in the buffer given to `match`, in the same
            /// order and still percent-encoded.
            names: []const []const u8,
        },
        /// The path exists, but not for this method. HEAD is in the set
        /// whenever GET is.
        wrong_method: std.EnumSet(Method),
        not_found,
    };
}

pub fn Table(comptime Handler: type, comptime routes: []const Route(Handler)) type {
    const Compiled = struct {
        method: Method,
        handler: Handler,
        segments: []const Segment,
        names: []const []const u8,
    };

    const compiled: []const Compiled, const most_params: usize = comptime blk: {
        @setEvalBranchQuota(10_000 + routes.len * routes.len * 100);
        var out: [routes.len]Compiled = undefined;
        var most: usize = 0;
        for (routes, &out) |r, *c| {
            const segments = split(r.pattern);
            var names: []const []const u8 = &.{};
            for (segments) |s| switch (s) {
                .param => |name| names = names ++ .{name},
                .literal => {},
            };
            c.* = .{ .method = r.method, .handler = r.handler, .segments = segments, .names = names };
            most = @max(most, names.len);
        }
        for (out, 0..) |a, i| for (out[0..i], routes[0..i]) |b, earlier| {
            if (a.method == b.method and sameShape(a.segments, b.segments)) {
                @compileError(std.fmt.comptimePrint("\"{t} {s}\" and \"{t} {s}\" match the same requests", .{
                    b.method, earlier.pattern, a.method, routes[i].pattern,
                }));
            }
        };
        const final = out;
        break :blk .{ &final, most };
    };

    return struct {
        pub const max_params = most_params;

        /// A HEAD request goes to the GET route when there is no HEAD
        /// route for the path.
        pub fn match(method: Method, path: []const u8, values: *[max_params][]const u8) Match(Handler) {
            const i = find(method, path, values) orelse
                (if (method == .HEAD) find(.GET, path, values) else null) orelse {
                const allowed = allow(path);
                if (allowed.count() == 0) return .not_found;
                return .{ .wrong_method = allowed };
            };
            return .{ .found = .{ .handler = compiled[i].handler, .names = compiled[i].names } };
        }

        fn find(method: Method, path: []const u8, values: *[max_params][]const u8) ?usize {
            var best: ?usize = null;
            var scratch: [max_params][]const u8 = undefined;
            for (compiled, 0..) |r, i| {
                if (r.method != method) continue;
                if (!matches(r.segments, path, &scratch)) continue;
                if (best) |b| if (!beats(r.segments, compiled[b].segments)) continue;
                best = i;
                values.* = scratch;
            }
            return best;
        }

        fn allow(path: []const u8) std.EnumSet(Method) {
            var set: std.EnumSet(Method) = .initEmpty();
            var scratch: [max_params][]const u8 = undefined;
            for (compiled) |r| {
                if (matches(r.segments, path, &scratch)) set.insert(r.method);
            }
            if (set.contains(.GET)) set.insert(.HEAD);
            return set;
        }
    };
}

fn split(comptime pattern: []const u8) []const Segment {
    if (pattern.len == 0 or pattern[0] != '/') {
        @compileError("route \"" ++ pattern ++ "\" has to start with /");
    }
    if (std.mem.indexOfAny(u8, pattern, "?#") != null) {
        @compileError("route \"" ++ pattern ++ "\" can't have a query or a fragment");
    }
    var out: []const Segment = &.{};
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    while (it.next()) |s| {
        if (s[0] != ':') {
            out = out ++ .{Segment{ .literal = s }};
            continue;
        }
        const name = s[1..];
        if (name.len == 0) @compileError("route \"" ++ pattern ++ "\" has a param with no name");
        for (out) |seen| switch (seen) {
            .param => |other| if (std.mem.eql(u8, other, name)) {
                @compileError("route \"" ++ pattern ++ "\" has two params called " ++ name);
            },
            .literal => {},
        };
        out = out ++ .{Segment{ .param = name }};
    }
    return out;
}

fn sameShape(a: []const Segment, b: []const Segment) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| switch (x) {
        .param => if (y != .param) return false,
        .literal => |l| switch (y) {
            .param => return false,
            .literal => |m| if (!std.mem.eql(u8, l, m)) return false,
        },
    };
    return true;
}

/// Only called for two routes that matched the same path, so they have
/// the same number of segments.
fn beats(a: []const Segment, b: []const Segment) bool {
    for (a, b) |x, y| {
        if (x == .literal and y == .param) return true;
        if (x == .param and y == .literal) return false;
    }
    return false;
}

fn matches(segments: []const Segment, path: []const u8, values: [][]const u8) bool {
    var it = std.mem.tokenizeScalar(u8, path, '/');
    var n: usize = 0;
    for (segments) |s| {
        const got = it.next() orelse return false;
        switch (s) {
            .literal => |l| if (!percent.eql(got, l, false)) return false,
            .param => {
                values[n] = got;
                n += 1;
            },
        }
    }
    return it.next() == null;
}

const testing = std.testing;

const T = Table(u8, &.{
    .get("/health", 1),
    .get("/recipes", 2),
    .post("/recipes", 3),
    .get("/recipes/:slug", 4),
    .get("/recipes/new", 5),
    .post("/recipes/:slug/report", 6),
    .get("/users/:id/recipes/:slug", 7),
    .on(.HEAD, "/big", 8),
    .get("/big", 9),
});

fn expectFound(want: u8, method: Method, path: []const u8) !void {
    var values: [T.max_params][]const u8 = undefined;
    const m = T.match(method, path, &values);
    try testing.expectEqual(want, m.found.handler);
}

test "a static path matches" {
    try expectFound(1, .GET, "/health");
}

test "the method picks between routes on one path" {
    try expectFound(2, .GET, "/recipes");
    try expectFound(3, .POST, "/recipes");
}

test "params are captured in order" {
    var values: [T.max_params][]const u8 = undefined;
    const m = T.match(.GET, "/users/42/recipes/sarma", &values);
    try testing.expectEqual(@as(u8, 7), m.found.handler);
    try testing.expectEqual(@as(usize, 2), m.found.names.len);
    try testing.expectEqualStrings("id", m.found.names[0]);
    try testing.expectEqualStrings("42", values[0]);
    try testing.expectEqualStrings("slug", m.found.names[1]);
    try testing.expectEqualStrings("sarma", values[1]);
}

test "param values are left encoded" {
    var values: [T.max_params][]const u8 = undefined;
    _ = T.match(.GET, "/recipes/a%20b", &values);
    try testing.expectEqualStrings("a%20b", values[0]);
}

test "a literal beats a param whatever the order" {
    try expectFound(5, .GET, "/recipes/new");
    try expectFound(4, .GET, "/recipes/old");
}

test "literals match encoded paths" {
    try expectFound(1, .GET, "/heal%74h");
}

test "HEAD goes to GET unless there is a HEAD route" {
    try expectFound(1, .HEAD, "/health");
    try expectFound(8, .HEAD, "/big");
}

test "an unknown path is not found" {
    var values: [T.max_params][]const u8 = undefined;
    try testing.expect(T.match(.GET, "/nothing", &values) == .not_found);
    try testing.expect(T.match(.GET, "/health/extra", &values) == .not_found);
    try testing.expect(T.match(.GET, "/", &values) == .not_found);
}

test "a known path with the wrong method lists what it allows" {
    var values: [T.max_params][]const u8 = undefined;
    const allowed = T.match(.DELETE, "/recipes", &values).wrong_method;
    try testing.expect(allowed.contains(.GET));
    try testing.expect(allowed.contains(.HEAD));
    try testing.expect(allowed.contains(.POST));
    try testing.expectEqual(@as(usize, 3), allowed.count());
}

test "a path that only has POST doesn't allow HEAD" {
    var values: [T.max_params][]const u8 = undefined;
    const allowed = T.match(.GET, "/recipes/x/report", &values).wrong_method;
    try testing.expectEqual(@as(usize, 1), allowed.count());
    try testing.expect(allowed.contains(.POST));
}

test "empty segments don't count" {
    try expectFound(1, .GET, "/health/");
    try expectFound(1, .GET, "//health");
}

test "a table with no params" {
    const Plain = Table(u8, &.{.get("/", 1)});
    var values: [Plain.max_params][]const u8 = undefined;
    try testing.expectEqual(@as(u8, 1), Plain.match(.GET, "/", &values).found.handler);
}
