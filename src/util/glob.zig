const std = @import("std");

pub fn match(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;

    var star: ?usize = null;
    var star_t: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_t = t;
            p += 1;
        } else if (p < pattern.len and pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (star) |s| {
            p = s + 1;
            star_t += 1;
            t = star_t;
        } else {
            return false;
        }
    }

    while (p < pattern.len and pattern[p] == '*') p += 1;

    return p == pattern.len;
}

test "exact matches" {
    try std.testing.expect(match("zen", "zen"));
    try std.testing.expect(!match("zen", "zen-browser"));
    try std.testing.expect(!match("zen", "Zen"));
    try std.testing.expect(!match("zen", ""));
    try std.testing.expect(match("", ""));
    try std.testing.expect(!match("", "zen"));
}

test "stars in every position" {
    try std.testing.expect(match("*", "anything"));
    try std.testing.expect(match("*", ""));

    try std.testing.expect(match("zen*", "zen-browser"));
    try std.testing.expect(match("zen*", "zen"));
    try std.testing.expect(!match("zen*", "Zen"));

    try std.testing.expect(match("*browser", "zen-browser"));
    try std.testing.expect(match("*browser", "browser"));

    try std.testing.expect(match("*Picture-in-Picture*", "Firefox — Picture-in-Picture"));
    try std.testing.expect(!match("*Picture-in-Picture*", "Firefox"));

    try std.testing.expect(match("org.*.Nautilus", "org.gnome.Nautilus"));
    try std.testing.expect(!match("org.*.Nautilus", "org.gnome.Files"));
}

test "several stars, and the backtracking they need" {
    try std.testing.expect(match("*a*b*", "xxaxxbxx"));
    try std.testing.expect(!match("*a*b*", "xxbxxaxx"));

    // The first star must give characters back for the second to match.
    try std.testing.expect(match("*ab*", "aaab"));
    try std.testing.expect(match("a*a*a", "aaaa"));

    // Adjacent stars are the same as one.
    try std.testing.expect(match("**zen**", "zen"));
}

test "a pattern that cannot match does not loop forever" {
    // Worth pinning: the backtracking loop is the one place this could spin.
    try std.testing.expect(!match("*z", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expect(!match("a*b*c*d", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}
