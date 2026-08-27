const std = @import("std");

const wm = &@import("../Delta.zig").instance;
const geom = @import("../util/geom.zig");

const rules = @import("rules.zig");

const Window = @import("../Window.zig");

const Eddy = @This();

root: ?Node = null,

pub const split_bias: f32 = 1.0;
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
    rect: geom.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

const ratio_min = 0.05;
const ratio_max = 0.95;

pub fn isEmpty(layout: *const Eddy) bool {
    return layout.root == null;
}

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

    const box = target.slot;
    const split: Split = if (@as(f32, @floatFromInt(box.width)) >
        @as(f32, @floatFromInt(box.height)) * split_bias)
        .vertical
    else
        .horizontal;

    var first: Node = .{ .window = target };
    var second: Node = .{ .window = window };

    if (cursor) |c| {
        const before = switch (split) {
            .vertical => c.x < box.x + @divTrunc(box.width, 2),
            .horizontal => c.y < box.y + @divTrunc(box.height, 2),
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

pub fn arrange(layout: *Eddy, area: geom.Rect) void {
    const root = layout.root orelse return;
    place(root, area, area);
}

pub fn windowAt(layout: *Eddy, point: geom.Point) ?*Window {
    var node = layout.root orelse return null;
    while (true) {
        switch (node) {
            .window => |w| return w,
            .branch => |b| {
                const halves = subdivide(b.rect, b.split, b.ratio);
                node = if (contains(halves[0], point)) b.children[0] else b.children[1];
            },
        }
    }
}

pub fn resize(window: *Window, dx: i32, dy: i32) void {
    if (nearest(window, .vertical)) |v| {
        if (v.branch.rect.width > 0) {
            const d = @as(f32, @floatFromInt(dx)) / @as(f32, @floatFromInt(v.branch.rect.width));
            v.branch.ratio = std.math.clamp(v.branch.ratio + v.sign * d, ratio_min, ratio_max);
        }
    }
    if (nearest(window, .horizontal)) |h| {
        if (h.branch.rect.height > 0) {
            const d = @as(f32, @floatFromInt(dy)) / @as(f32, @floatFromInt(h.branch.rect.height));
            h.branch.ratio = std.math.clamp(h.branch.ratio + h.sign * d, ratio_min, ratio_max);
        }
    }
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

fn contains(rect: geom.Rect, point: geom.Point) bool {
    return point.x >= rect.x and point.x < rect.x + rect.width and
        point.y >= rect.y and point.y < rect.y + rect.height;
}

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
