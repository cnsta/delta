const std = @import("std");
const wm = &@import("../Delta.zig").instance;
const geom = @import("../util/geom.zig");
const Seat = @import("../Seat.zig");
const Window = @import("../Window.zig");
const Workspace = @import("../Workspace.zig");

pub const gap = 4;

const ratio_min = 0.05;
const ratio_max = 0.95;

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

pub fn insert(ws: *Workspace, window: *Window, near: ?*Window, cursor: ?geom.Point) void {
    window.branch = null;

    if (ws.root == null) {
        ws.root = .{ .window = window };
        return;
    }

    const target = near orelse firstWindow(ws.root.?);
    if (target == window) return;

    const parent = target.branch;
    const index = if (parent) |p| indexOf(p, .{ .window = target }) else 0;
    const split: Split = if (target.width > target.height) .vertical else .horizontal;

    var first: Node = .{ .window = target };
    var second: Node = .{ .window = window };

    if (cursor) |c| {
        const before = switch (split) {
            .vertical => c.x < target.x + @divTrunc(target.width, 2),
            .horizontal => c.y < target.y + @divTrunc(target.height, 2),
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
        ws.root = .{ .branch = branch };
    }
}

pub fn remove(ws: *Workspace, window: *Window) void {
    const parent = window.branch orelse {
        if (ws.root) |root| switch (root) {
            .window => |w| if (w == window) {
                ws.root = null;
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
        ws.root = sibling;
    }

    wm.gpa.destroy(parent);
    window.branch = null;
}

pub fn swap(ws: *Workspace, a: *Window, b: *Window) void {
    if (a == b) return;

    const pa = a.branch;
    const pb = b.branch;
    const ia = if (pa) |p| indexOf(p, .{ .window = a }) else 0;
    const ib = if (pb) |p| indexOf(p, .{ .window = b }) else 0;

    if (pa) |p| {
        p.children[ia] = .{ .window = b };
    } else {
        ws.root = .{ .window = b };
    }
    if (pb) |p| {
        p.children[ib] = .{ .window = a };
    } else {
        ws.root = .{ .window = a };
    }

    a.branch = pb;
    b.branch = pa;
}

pub fn arrange(ws: *Workspace, area: geom.Rect) void {
    const root = ws.root orelse return;
    place(root, area);
}

pub fn windowAt(ws: *Workspace, point: geom.Point) ?*Window {
    var node = ws.root orelse return null;
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

pub fn cursorIn(ws: *Workspace) ?geom.Point {
    const origin = ws.origin() orelse return null;
    const seat = wm.seats.first() orelse return null;
    if (!seat.pointer_known) return null;

    return .{
        .x = seat.pointer.x - origin.x,
        .y = seat.pointer.y - origin.y,
    };
}

fn place(node: Node, rect: geom.Rect) void {
    switch (node) {
        .window => |w| {
            const inset = Window.border_width + gap;
            w.setPosition(rect.x + inset, rect.y + inset);
            w.obj.proposeDimensions(
                @max(1, rect.width - 2 * inset),
                @max(1, rect.height - 2 * inset),
            );
        },
        .branch => |b| {
            b.rect = rect;
            const halves = subdivide(rect, b.split, b.ratio);
            place(b.children[0], halves[0]);
            place(b.children[1], halves[1]);
        },
    }
}

fn subdivide(rect: geom.Rect, split: Split, ratio: f32) [2]geom.Rect {
    switch (split) {
        .vertical => {
            const cut = @max(0, @min(rect.width, split_at(rect.width, ratio)));
            return .{
                .{ .x = rect.x, .y = rect.y, .width = cut, .height = rect.height },
                .{ .x = rect.x + cut, .y = rect.y, .width = rect.width - cut, .height = rect.height },
            };
        },
        .horizontal => {
            const cut = @max(0, @min(rect.height, split_at(rect.height, ratio)));
            return .{
                .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = cut },
                .{ .x = rect.x, .y = rect.y + cut, .width = rect.width, .height = rect.height - cut },
            };
        },
    }
}

fn split_at(extent: i32, ratio: f32) i32 {
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
