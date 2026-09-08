const std = @import("std");

const geom = @import("../util/geom.zig");
const wm = &@import("../Delta.zig").instance;

const Output = @import("../Output.zig");

pub fn between() i32 {
    return wm.config.gaps.between;
}

fn edge() i32 {
    return wm.config.gaps.edge;
}

pub fn borderWidth() i32 {
    return wm.config.border.width;
}

pub fn resizeStep() i32 {
    return wm.config.layout.resize_step;
}

pub const Limits = struct {
    min: geom.Size = geom.Size.zero,
    max: geom.Size = geom.Size.zero,
};

pub const Edges = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub fn eql(a: Edges, b: Edges) bool {
        return a.top == b.top and a.bottom == b.bottom and
            a.left == b.left and a.right == b.right;
    }
};

pub const Placement = struct {
    content: geom.Rect,
    tiled: Edges,
};

pub fn workArea(output: *const Output) geom.Rect {
    const usable = output.usableArea();
    const outer = edge();

    return .{
        .x = usable.x - output.x + outer,
        .y = usable.y - output.y + outer,
        .width = @max(1, usable.width - 2 * outer),
        .height = @max(1, usable.height - 2 * outer),
    };
}

pub fn place(box: geom.Rect, area: geom.Rect, limits: Limits) Placement {
    const half = @divExact(between(), 2);
    const border = borderWidth();

    const tiled: Edges = .{
        .left = !sticks(box.x, area.x),
        .top = !sticks(box.y, area.y),
        .right = !sticks(box.x + box.width, area.x + area.width),
        .bottom = !sticks(box.y + box.height, area.y + area.height),
    };

    const left = border + if (tiled.left) half else 0;
    const top = border + if (tiled.top) half else 0;
    const right = border + if (tiled.right) half else 0;
    const bottom = border + if (tiled.bottom) half else 0;

    var content: geom.Rect = .{
        .x = box.x + left,
        .y = box.y + top,
        .width = @max(1, box.width - left - right),
        .height = @max(1, box.height - top - bottom),
    };

    clamp(&content, limits, area);

    return .{ .content = content, .tiled = tiled };
}

pub fn placeFloat(box: geom.Rect, area: geom.Rect, limits: Limits) Placement {
    var content = box;

    if (limits.min.width > 0) content.width = @max(content.width, limits.min.width);
    if (limits.max.width > 0) content.width = @min(content.width, limits.max.width);
    if (limits.min.height > 0) content.height = @max(content.height, limits.min.height);
    if (limits.max.height > 0) content.height = @min(content.height, limits.max.height);

    keepReachable(&content, area);

    return .{ .content = content, .tiled = .{} };
}

fn keepReachable(content: *geom.Rect, area: geom.Rect) void {
    const border = borderWidth();
    const show_x = std.math.clamp(@divTrunc(content.width, 4), 10, 75) + border;
    const show_y = std.math.clamp(@divTrunc(content.height, 4), 10, 75) + border;

    content.x = std.math.clamp(
        content.x,
        area.x + show_x - content.width,
        area.x + area.width - show_x,
    );
    content.y = std.math.clamp(
        content.y,
        area.y + show_y - content.height,
        area.y + area.height - show_y,
    );
}

fn clamp(content: *geom.Rect, limits: Limits, area: geom.Rect) void {
    var width = content.width;
    var height = content.height;

    if (limits.min.width > 0) width = @max(width, limits.min.width);
    if (limits.max.width > 0) width = @min(width, limits.max.width);
    if (limits.min.height > 0) height = @max(height, limits.min.height);
    if (limits.max.height > 0) height = @min(height, limits.max.height);

    if (width == content.width and height == content.height) return;

    content.x += @divTrunc(content.width - width, 2);
    content.y += @divTrunc(content.height - height, 2);
    content.width = width;
    content.height = height;

    content.x = std.math.clamp(content.x, area.x, @max(area.x, area.x + area.width - width));
    content.y = std.math.clamp(content.y, area.y, @max(area.y, area.y + area.height - height));
}

fn sticks(a: i32, b: i32) bool {
    return @abs(a - b) <= 1;
}

pub fn showDesktopDirection(
    is_float: bool,
    escape: ?geom.Direction,
    box: geom.Rect,
    output: *const Output,
    blocked: geom.Edges,
) geom.Direction {
    const primary = if (is_float) floatDirection(box, output, blocked) else escape;
    return primary orelse fallbackDirection(blocked);
}

fn floatDirection(box: geom.Rect, output: *const Output, blocked: geom.Edges) ?geom.Direction {
    if (box.width == 0 or box.height == 0) return null;

    const c = output.rect().center();
    const wc = box.center();
    const dx = wc.x - c.x;
    const dy = wc.y - c.y;

    const primary: geom.Direction = if (@abs(dx) >= @abs(dy))
        (if (dx >= 0) .right else .left)
    else
        (if (dy >= 0) .down else .up);
    if (!blocked.blocks(primary)) return primary;

    const secondary: geom.Direction = if (primary == .left or primary == .right)
        (if (dy >= 0) .down else .up)
    else
        (if (dx >= 0) .right else .left);
    if (!blocked.blocks(secondary)) return secondary;

    return null;
}

fn fallbackDirection(blocked: geom.Edges) geom.Direction {
    if (blocked.top) return .down;
    if (blocked.bottom) return .up;
    if (blocked.left) return .right;
    if (blocked.right) return .left;
    return .down;
}

pub fn desktopClearance(box: geom.Rect, dir: geom.Direction, output: *const Output) i32 {
    return switch (dir) {
        .left, .right => output.width + @max(0, box.width),
        .up, .down => output.height + @max(0, box.height),
    };
}

pub fn useDefaultConfig() void {
    wm.config = .{};
    wm.gpa = std.testing.allocator;
}

test "place gives equal gaps regardless of how the area was divided" {
    useDefaultConfig();
    const border = borderWidth();

    const area: geom.Rect = .{ .x = 10, .y = 10, .width = 200, .height = 100 };

    const left = place(.{ .x = 10, .y = 10, .width = 100, .height = 100 }, area, .{});
    const right = place(.{ .x = 110, .y = 10, .width = 100, .height = 100 }, area, .{});

    const left_border_end = left.content.x + left.content.width + border;
    const right_border_start = right.content.x - border;
    try std.testing.expectEqual(between(), right_border_start - left_border_end);

    try std.testing.expectEqual(area.x + border, left.content.x);
    try std.testing.expectEqual(
        area.x + area.width - border,
        right.content.x + right.content.width,
    );

    try std.testing.expect(left.tiled.right and !left.tiled.left);
    try std.testing.expect(right.tiled.left and !right.tiled.right);
    try std.testing.expect(!left.tiled.top and !left.tiled.bottom);
}

test "keepReachable leaves a grabbable strip on screen" {
    useDefaultConfig();

    const area: geom.Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 1000 };

    const off_right = placeFloat(.{ .x = 5000, .y = 100, .width = 400, .height = 300 }, area, .{});
    try std.testing.expect(off_right.content.x < area.x + area.width);
    try std.testing.expect(off_right.content.x + off_right.content.width > area.x + area.width);

    const off_left = placeFloat(.{ .x = -5000, .y = 100, .width = 400, .height = 300 }, area, .{});
    try std.testing.expect(off_left.content.x + off_left.content.width > area.x);

    const inside: geom.Rect = .{ .x = 100, .y = 100, .width = 400, .height = 300 };
    try std.testing.expect(placeFloat(inside, area, .{}).content.eql(inside));
}

test "sticks absorbs the pixel lost to integer subdivision" {
    useDefaultConfig();

    const area: geom.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 101 };

    const lower = place(.{ .x = 0, .y = 50, .width = 100, .height = 50 }, area, .{});
    try std.testing.expect(!lower.tiled.bottom);
    try std.testing.expect(lower.tiled.top);
}

test "clamp centres a window that cannot shrink to its box" {
    useDefaultConfig();

    const area: geom.Rect = .{ .x = 0, .y = 0, .width = 400, .height = 400 };
    const box: geom.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 400 };

    const wide = place(box, area, .{ .min = .{ .width = 200, .height = 0 } });
    try std.testing.expectEqual(@as(i32, 200), wide.content.width);

    try std.testing.expect(wide.content.x >= area.x);
    try std.testing.expect(wide.content.x + wide.content.width <= area.x + area.width);
}

fn testOutput(x: i32, y: i32, width: i32, height: i32) Output {
    var output: Output = undefined;
    output.x = x;
    output.y = y;
    output.width = width;
    output.height = height;
    return output;
}

test "showDesktopDirection uses the tiled escape direction when not floating" {
    const output = testOutput(0, 0, 1000, 1000);
    const box: geom.Rect = .{ .x = 0, .y = 0, .width = 500, .height = 1000 };

    try std.testing.expectEqual(
        geom.Direction.left,
        showDesktopDirection(false, .left, box, &output, .{}),
    );
}

test "showDesktopDirection picks a float quadrant direction" {
    const output = testOutput(0, 0, 1000, 1000);
    // box centre is (800, 500), output centre is (500, 500): straight right.
    const box: geom.Rect = .{ .x = 700, .y = 400, .width = 200, .height = 200 };

    try std.testing.expectEqual(
        geom.Direction.right,
        showDesktopDirection(true, null, box, &output, .{}),
    );
}

test "showDesktopDirection falls back away from a bar when nothing else applies" {
    const output = testOutput(0, 0, 1000, 1000);

    try std.testing.expectEqual(
        geom.Direction.down,
        showDesktopDirection(true, null, geom.Rect.zero, &output, .{ .top = true }),
    );
    try std.testing.expectEqual(
        geom.Direction.up,
        showDesktopDirection(false, null, geom.Rect.zero, &output, .{ .bottom = true }),
    );
    try std.testing.expectEqual(
        geom.Direction.right,
        showDesktopDirection(false, null, geom.Rect.zero, &output, .{ .left = true }),
    );
    try std.testing.expectEqual(
        geom.Direction.left,
        showDesktopDirection(false, null, geom.Rect.zero, &output, .{ .right = true }),
    );
}

test "desktopClearance measures the full off-screen distance" {
    const output = testOutput(0, 0, 1000, 600);
    const box: geom.Rect = .{ .x = 0, .y = 0, .width = 200, .height = 100 };

    try std.testing.expectEqual(@as(i32, 1200), desktopClearance(box, .left, &output));
    try std.testing.expectEqual(@as(i32, 1200), desktopClearance(box, .right, &output));
    try std.testing.expectEqual(@as(i32, 700), desktopClearance(box, .up, &output));
    try std.testing.expectEqual(@as(i32, 700), desktopClearance(box, .down, &output));
}
