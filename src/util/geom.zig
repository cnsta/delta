pub const Point = struct {
    x: i32,
    y: i32,

    pub const zero: Point = .{ .x = 0, .y = 0 };

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
};

pub const Size = struct {
    width: i32,
    height: i32,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn origin(r: Rect) Point {
        return .{ .x = r.x, .y = r.y };
    }
};
