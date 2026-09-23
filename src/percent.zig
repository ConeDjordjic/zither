//! Comparing percent-encoded bytes with plain ones, without decoding
//! into a buffer first.

const std = @import("std");

/// Does `raw`, once decoded, equal `plain`? A bad escape is never equal.
/// With `plus_is_space` a `+` counts as a space, the way it does in a
/// query.
pub fn eql(raw: []const u8, plain: []const u8, plus_is_space: bool) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < raw.len) : (j += 1) {
        if (j == plain.len) return false;
        var c = raw[i];
        if (c == '%') {
            if (i + 2 >= raw.len) return false;
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return false;
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return false;
            c = hi * 16 + lo;
            i += 3;
        } else {
            if (plus_is_space and c == '+') c = ' ';
            i += 1;
        }
        if (c != plain[j]) return false;
    }
    return j == plain.len;
}

const testing = std.testing;

test "plain bytes compare as they are" {
    try testing.expect(eql("recipes", "recipes", false));
    try testing.expect(!eql("recipes", "recipe", false));
    try testing.expect(!eql("recipe", "recipes", false));
    try testing.expect(eql("", "", false));
}

test "escapes are decoded before comparing" {
    try testing.expect(eql("a%20b", "a b", false));
    try testing.expect(eql("%C3%A4", "ä", false));
    try testing.expect(eql("%2f", "/", false));
    try testing.expect(!eql("%2f", "%2f", false));
}

test "a bad escape never matches" {
    for ([_][]const u8{ "%", "%2", "%zz", "a%" }) |bad| {
        try testing.expect(!eql(bad, bad, false));
    }
}

test "a plus is a space only when asked" {
    try testing.expect(eql("a+b", "a b", true));
    try testing.expect(eql("a+b", "a+b", false));
    try testing.expect(eql("a%2Bb", "a+b", true));
}
