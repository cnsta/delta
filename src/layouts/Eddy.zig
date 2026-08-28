const std = @import("std");

const wm = &@import("../Delta.zig").instance;
const geom = @import("../util/geom.zig");

const rules = @import("rules.zig");

const Window = @import("../Window.zig");

const Eddy = @This();

root: ?Node = null,

pub const Split = enum { vertical, horizontal };

pub const Node = union(enum) {
    window: *Window,
    branch: *Branch,
};

pub const Branch = struct {
    parent: ?*Branch = null,
    children: [2]Node,
    split: Split,
    ratio: f32 = 0.5,

    rect: geom.Rect = geom.Rect.zero,
};

const ratio_min = 0.05;
const ratio_max = 0.95;
const min_pane = 64;

// -- queries -------------------------------------------------------------

pub fn isEmpty(layout: *const Eddy) bool {
    return layout.root == null;
}

pub fn windowAt(layout: *Eddy, point: geom.Point) ?*Window {
    var node = layout.root orelse return null;
    while (true) {
        switch (node) {
            .window => |w| return w,
            .branch => |b| {
                const halves = subdivide(b.rect, b.split, b.ratio);
                node = if (halves[0].contains(point)) b.children[0] else b.children[1];
            },
        }
    }
}

// -- tree mutation -------------------------------------------------------

pub fn insert(layout: *Eddy, window: *Window, near: ?*Window, cursor: ?geom.Point) void {
    window.branch = null;

    const root = layout.root orelse {
        layout.root = .{ .window = window };
        return;
    };

    const target = near orelse firstWindow(root);
    if (target == window) return;

    const parent = target.branch;
    const index = if (parent) |p| indexOf(p, .{ .window = target }) else 0;

    const bias = wm.config.layout.split_bias;
    const box = target.slot;
    const split: Split = if (@as(f32, @floatFromInt(box.width)) >
        @as(f32, @floatFromInt(box.height)) * bias)
        .vertical
    else
        .horizontal;

    var first: Node = .{ .window = target };
    var second: Node = .{ .window = window };

    if (cursor) |c| {
        const middle = box.center();
        const before = switch (split) {
            .vertical => c.x < middle.x,
            .horizontal => c.y < middle.y,
        };
        if (before) {
            first = .{ .window = window };
            second = .{ .window = target };
        }
    }

    const branch = wm.gpa.create(Branch) catch std.process.fatal("Out of memory.", .{});
    branch.* = .{
        .parent = parent,
        .children = .{ first, second },
        .split = split,
    };
    setParent(first, branch);
    setParent(second, branch);

    if (parent) |p| {
        p.children[index] = .{ .branch = branch };
    } else {
        layout.root = .{ .branch = branch };
    }
}

pub fn remove(layout: *Eddy, window: *Window) void {
    const parent = window.branch orelse {
        // No parent means it is either the root or not in this tree at all.
        if (layout.root) |root| switch (root) {
            .window => |w| if (w == window) {
                layout.root = null;
            },
            .branch => {},
        };
        return;
    };

    const index = indexOf(parent, .{ .window = window });
    const sibling = parent.children[index ^ 1];
    const grandparent = parent.parent;

    setParent(sibling, grandparent);
    if (grandparent) |g| {
        g.children[indexOf(g, .{ .branch = parent })] = sibling;
    } else {
        layout.root = sibling;
    }

    wm.gpa.destroy(parent);
    window.branch = null;
}

pub fn swap(layout: *Eddy, a: *Window, b: *Window) void {
    if (a == b) return;

    const pa = a.branch;
    const pb = b.branch;
    const ia = if (pa) |p| indexOf(p, .{ .window = a }) else 0;
    const ib = if (pb) |p| indexOf(p, .{ .window = b }) else 0;

    if (pa) |p| {
        p.children[ia] = .{ .window = b };
    } else {
        layout.root = .{ .window = b };
    }
    if (pb) |p| {
        p.children[ib] = .{ .window = a };
    } else {
        layout.root = .{ .window = a };
    }

    a.branch = pb;
    b.branch = pa;
}

// -- arrangement ---------------------------------------------------------

pub fn arrange(layout: *Eddy, area: geom.Rect) void {
    const root = layout.root orelse return;
    place(root, area, area);
}

fn place(node: Node, rect: geom.Rect, area: geom.Rect) void {
    switch (node) {
        .window => |w| w.applyPlacement(rules.place(rect, area, w.limits)),
        .branch => |b| {
            b.rect = rect;
            const halves = subdivide(rect, b.split, b.ratio);
            place(b.children[0], halves[0], area);
            place(b.children[1], halves[1], area);
        },
    }
}

fn subdivide(rect: geom.Rect, split: Split, ratio: f32) [2]geom.Rect {
    switch (split) {
        .vertical => {
            const cut = std.math.clamp(scale(rect.width, ratio), 0, rect.width);
            return .{
                .{ .x = rect.x, .y = rect.y, .width = cut, .height = rect.height },
                .{ .x = rect.x + cut, .y = rect.y, .width = rect.width - cut, .height = rect.height },
            };
        },
        .horizontal => {
            const cut = std.math.clamp(scale(rect.height, ratio), 0, rect.height);
            return .{
                .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = cut },
                .{ .x = rect.x, .y = rect.y + cut, .width = rect.width, .height = rect.height - cut },
            };
        },
    }
}

fn scale(extent: i32, ratio: f32) i32 {
    return @intFromFloat(@as(f32, @floatFromInt(extent)) * ratio);
}

// -- resizing ------------------------------------------------------------

pub fn resize(window: *Window, dx: i32, dy: i32) void {
    if (dx != 0) {
        if (nearest(window, .vertical)) |v| {
            applyRatio(v.branch, v.sign * ratioDelta(dx, v.branch.rect.width));
        }
    }
    if (dy != 0) {
        if (nearest(window, .horizontal)) |h| {
            applyRatio(h.branch, h.sign * ratioDelta(dy, h.branch.rect.height));
        }
    }
}

fn ratioDelta(pixels: i32, extent: i32) f32 {
    if (extent <= 0) return 0;
    return @as(f32, @floatFromInt(pixels)) / @as(f32, @floatFromInt(extent));
}

fn applyRatio(branch: *Branch, delta: f32) void {
    if (delta == 0) return;

    const extent = switch (branch.split) {
        .vertical => branch.rect.width,
        .horizontal => branch.rect.height,
    };
    if (extent <= 0) return;

    const first = minExtent(branch.children[0], branch.split);
    const second = minExtent(branch.children[1], branch.split);

    const low = @max(ratio_min, ratioDelta(first, extent));
    const high = @min(ratio_max, 1 - ratioDelta(second, extent));

    if (low > high) return;

    branch.ratio = std.math.clamp(branch.ratio + delta, low, high);
}

fn minExtent(node: Node, axis: Split) i32 {
    switch (node) {
        .window => |w| {
            const wanted = switch (axis) {
                .vertical => w.limits.min.width,
                .horizontal => w.limits.min.height,
            };
            return @max(min_pane, wanted + 2 * rules.borderWidth() + rules.between());
        },
        .branch => |b| {
            const first = minExtent(b.children[0], axis);
            const second = minExtent(b.children[1], axis);
            return if (b.split == axis) first + second else @max(first, second);
        },
    }
}

// -- node helpers --------------------------------------------------------

fn nearest(window: *Window, want: Split) ?struct { branch: *Branch, sign: f32 } {
    var node: Node = .{ .window = window };
    while (parentOf(node)) |b| : (node = .{ .branch = b }) {
        if (b.split != want) continue;
        return .{
            .branch = b,
            .sign = if (indexOf(b, node) == 0) 1.0 else -1.0,
        };
    }
    return null;
}

fn firstWindow(node: Node) *Window {
    var current = node;
    while (true) {
        switch (current) {
            .window => |w| return w,
            .branch => |b| current = b.children[0],
        }
    }
}

fn parentOf(node: Node) ?*Branch {
    return switch (node) {
        .window => |w| w.branch,
        .branch => |b| b.parent,
    };
}

fn setParent(node: Node, parent: ?*Branch) void {
    switch (node) {
        .window => |w| w.branch = parent,
        .branch => |b| b.parent = parent,
    }
}

fn eql(a: Node, b: Node) bool {
    return switch (a) {
        .window => |aw| switch (b) {
            .window => |bw| aw == bw,
            .branch => false,
        },
        .branch => |ab| switch (b) {
            .window => false,
            .branch => |bb| ab == bb,
        },
    };
}

fn indexOf(parent: *Branch, child: Node) u1 {
    if (eql(parent.children[0], child)) return 0;

    std.debug.assert(eql(parent.children[1], child));
    return 1;
}

test "subdivide halves tile the original exactly" {
    for ([_]i32{ 1, 2, 3, 99, 100, 1439, 2560 }) |extent| {
        for ([_]f32{ 0.05, 0.5, 0.5001, 0.95 }) |ratio| {
            const rect: geom.Rect = .{ .x = 7, .y = 11, .width = extent, .height = extent };

            const v = subdivide(rect, .vertical, ratio);
            try std.testing.expectEqual(rect.width, v[0].width + v[1].width);
            try std.testing.expectEqual(v[0].x + v[0].width, v[1].x);
            try std.testing.expectEqual(rect.x, v[0].x);

            const h = subdivide(rect, .horizontal, ratio);
            try std.testing.expectEqual(rect.height, h[0].height + h[1].height);
            try std.testing.expectEqual(h[0].y + h[0].height, h[1].y);
            try std.testing.expectEqual(rect.y, h[0].y);
        }
    }
}

test "subdivide halves never both contain the shared edge" {
    const rect: geom.Rect = .{ .x = 0, .y = 0, .width = 101, .height = 101 };
    const halves = subdivide(rect, .vertical, 0.5);

    const edge: geom.Point = .{ .x = halves[1].x, .y = 50 };
    try std.testing.expect(!halves[0].contains(edge));
    try std.testing.expect(halves[1].contains(edge));
}
