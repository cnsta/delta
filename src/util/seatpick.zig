const std = @import("std");

const geom = @import("geom.zig");

pub const Focus = enum {
    none,
    valid,
    stale,
};

pub fn classifyFocus(focused: bool, has_workspace: bool, on_output: bool) Focus {
    if (!focused) return .none;
    if (!has_workspace or !on_output) return .stale;
    return .valid;
}

pub fn mayFallBack(focus: Focus) bool {
    return focus != .valid;
}

pub fn pointerWithin(known: bool, pointer: geom.Point, output: geom.Rect, origin: geom.Point) ?geom.Point {
    if (!known) return null;
    if (!output.contains(pointer)) return null;
    return .{ .x = pointer.x - origin.x, .y = pointer.y - origin.y };
}

test "an unfocused seat classifies as none" {
    try std.testing.expectEqual(Focus.none, classifyFocus(false, false, false));
    try std.testing.expectEqual(Focus.none, classifyFocus(false, true, true));
}

test "focus on a hidden or detached workspace is stale" {
    try std.testing.expectEqual(Focus.stale, classifyFocus(true, true, false));
    try std.testing.expectEqual(Focus.stale, classifyFocus(true, false, false));
    try std.testing.expectEqual(Focus.stale, classifyFocus(true, false, true));
}

test "focus on a shown workspace is valid" {
    try std.testing.expectEqual(Focus.valid, classifyFocus(true, true, true));
}

test "fallback is refused only for a valid focus" {
    try std.testing.expect(mayFallBack(.none));
    try std.testing.expect(mayFallBack(.stale));
    try std.testing.expect(!mayFallBack(.valid));
}

test "a pointer on another output yields no hint" {
    const left: geom.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const right: geom.Rect = .{ .x = 1920, .y = 0, .width = 1920, .height = 1080 };
    const pointer: geom.Point = .{ .x = 2000, .y = 100 };

    try std.testing.expectEqual(@as(?geom.Point, null), pointerWithin(true, pointer, left, left.origin()));
    const hint = pointerWithin(true, pointer, right, right.origin()).?;
    try std.testing.expect(hint.eql(.{ .x = 80, .y = 100 }));
}

test "an unknown pointer yields no hint" {
    const out: geom.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try std.testing.expectEqual(@as(?geom.Point, null), pointerWithin(false, .{ .x = 1, .y = 1 }, out, out.origin()));
}

test "the origin may include an animation offset" {
    const out: geom.Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 1000 };
    const hint = pointerWithin(true, .{ .x = 500, .y = 500 }, out, .{ .x = -200, .y = 0 }).?;
    try std.testing.expect(hint.eql(.{ .x = 700, .y = 500 }));
}
