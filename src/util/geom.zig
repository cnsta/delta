const std = @import("std");

pub const Point = struct {
    x: i32,
    y: i32,

    pub const zero: Point = .{ .x = 0, .y = 0 };

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }
};

pub const Size = struct {
    width: i32,
    height: i32,

    pub const zero: Size = .{ .width = 0, .height = 0 };

    pub fn eql(a: Size, b: Size) bool {
        return a.width == b.width and a.height == b.height;
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub const zero: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    pub fn origin(r: Rect) Point {
        return .{ .x = r.x, .y = r.y };
    }

    pub fn size(r: Rect) Size {
        return .{ .width = r.width, .height = r.height };
    }

    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.x < r.x + r.width and
            p.y >= r.y and p.y < r.y + r.height;
    }

    pub fn center(r: Rect) Point {
        return .{
            .x = r.x + @divTrunc(r.width, 2),
            .y = r.y + @divTrunc(r.height, 2),
        };
    }

    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and
            a.width == b.width and a.height == b.height;
    }
};

pub const Direction = enum {
    left,
    right,
    up,
    down,

    pub fn delta(dir: Direction, step: i32) Point {
        return switch (dir) {
            .left => .{ .x = -step, .y = 0 },
            .right => .{ .x = step, .y = 0 },
            .up => .{ .x = 0, .y = -step },
            .down => .{ .x = 0, .y = step },
        };
    }
};

pub const Edges = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub fn blocks(edges: Edges, dir: Direction) bool {
        return switch (dir) {
            .left => edges.left,
            .right => edges.right,
            .up => edges.top,
            .down => edges.bottom,
        };
    }
};

test "Rect.contains is half-open" {
    const left: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const right: Rect = .{ .x = 10, .y = 0, .width = 10, .height = 10 };

    const on_edge: Point = .{ .x = 10, .y = 5 };
    try std.testing.expect(!left.contains(on_edge));
    try std.testing.expect(right.contains(on_edge));

    try std.testing.expect(left.contains(.{ .x = 0, .y = 0 }));
    try std.testing.expect(!left.contains(.{ .x = 9, .y = 10 }));
}

test "Rect.center rounds toward the origin" {
    const odd: Rect = .{ .x = 0, .y = 0, .width = 5, .height = 5 };
    try std.testing.expect(odd.center().eql(.{ .x = 2, .y = 2 }));

    const negative: Rect = .{ .x = -10, .y = -10, .width = 5, .height = 5 };
    try std.testing.expect(negative.center().eql(.{ .x = -8, .y = -8 }));
}
