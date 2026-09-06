const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const geom = @import("util/geom.zig");

const Eddy = @import("layouts/Eddy.zig");
const animation = @import("util/animation.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");

const Workspace = @This();

id: Id,
link: wl.list.Link,

output: ?*Output = null,
last_output: ?*Output = null,
offset: animation.Lerp = .zero,

windows: wl.list.Head(Window, .workspace_link),
layout: Eddy = .{},

pub const Id = u32;

pub fn get(id: Id) *Workspace {
    var it = wm.workspaces.iterator(.forward);
    while (it.next()) |ws| {
        if (ws.id == id) return ws;

        // Sorted, so the first larger id is where this one belongs.
        if (ws.id > id) return insertBefore(&ws.link, id);
    }
    return insertBefore(&wm.workspaces.link, id);
}

pub fn firstUnmapped() *Workspace {
    var id: Id = 1;
    var it = wm.workspaces.iterator(.forward);
    while (it.next()) |ws| {
        if (ws.id > id) break;
        if (ws.id == id) {
            if (ws.output == null) return ws;
            id += 1;
        }
    }
    return get(id);
}

/// TODO: multi-seat
pub fn forNewWindow() *Workspace {
    if (wm.seats.first()) |seat| {
        if (seat.output) |output| return output.workspace;
    }
    if (wm.outputs.first()) |output| return output.workspace;
    return get(1);
}

pub fn maybeDestroy(ws: *Workspace) void {
    if (ws.output != null) return;
    if (ws.animating()) return;
    if (!ws.isEmpty()) return;
    wm.ipc_dirty = true;

    std.debug.assert(ws.layout.isEmpty());

    ws.link.remove();
    wm.gpa.destroy(ws);
}

fn insertBefore(before: *wl.list.Link, id: Id) *Workspace {
    const ws = wm.gpa.create(Workspace) catch fatal("Out of memory.", .{});
    ws.* = .{
        .id = id,
        .link = undefined,
        .windows = undefined,
    };
    ws.windows.init();

    before.prev.?.insert(&ws.link);
    wm.ipc_dirty = true;
    return ws;
}

pub fn arrange(ws: *Workspace, area: geom.Rect) void {
    ws.layout.arrange(area);

    var it = ws.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.floating) window.applyFloating(area);
    }
}

pub fn raiseFloating(ws: *Workspace) void {
    var it = ws.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.floating and window.visible()) window.node.placeTop();
    }
}

// -- queries -------------------------------------------------------------

pub fn isEmpty(ws: *const Workspace) bool {
    return ws.windows.empty();
}

pub fn visible(ws: *const Workspace) bool {
    return ws.output != null or ws.animating();
}

pub fn animating(ws: *const Workspace) bool {
    if (!wm.config.animation.enabled) return false;
    const duration = wm.config.animation.duration_ms;
    return !ws.offset.done(wm.millis(), duration);
}

pub fn settle(ws: *Workspace) void {
    const duration = if (wm.config.animation.enabled) wm.config.animation.duration_ms else 0;
    const now = wm.millis();

    if (ws.offset.done(now, duration)) {
        ws.offset.settle();
        if (ws.output == null) ws.last_output = null;
    }
}

pub fn origin(ws: *const Workspace) ?geom.Point {
    const output = ws.output orelse ws.last_output orelse return null;
    const duration = if (wm.config.animation.enabled) wm.config.animation.duration_ms else 0;
    const now = wm.millis();
    const off = ws.offset.at(now, duration, wm.config.animation.curve);

    return .{ .x = output.x + off.x, .y = output.y + off.y };
}

/// TODO: multi-seat
pub fn cursor(ws: *Workspace) ?geom.Point {
    const seat = wm.seats.first() orelse return null;
    if (!seat.pointer_known) return null;
    const topleft = ws.origin() orelse return null;

    return .{
        .x = seat.pointer.x - topleft.x,
        .y = seat.pointer.y - topleft.y,
    };
}

pub fn windowInDirection(ws: *Workspace, from: *Window, dir: geom.Direction) ?*Window {
    const a = from.slot;
    if (a.width == 0) return null;

    var best: ?*Window = null;
    var best_gap: i32 = std.math.maxInt(i32);

    var it = ws.windows.iterator(.forward);
    while (it.next()) |other| {
        if (other == from or other.slot.width == 0) continue;
        const b = other.slot;

        const overlaps = switch (dir) {
            .left, .right => b.y < a.y + a.height and a.y < b.y + b.height,
            .up, .down => b.x < a.x + a.width and a.x < b.x + b.width,
        };
        if (!overlaps) continue;

        const gap = switch (dir) {
            .left => if (b.x + b.width <= a.x) a.x - (b.x + b.width) else continue,
            .right => if (b.x >= a.x + a.width) b.x - (a.x + a.width) else continue,
            .up => if (b.y + b.height <= a.y) a.y - (b.y + b.height) else continue,
            .down => if (b.y >= a.y + a.height) b.y - (a.y + a.height) else continue,
        };

        if (gap < best_gap) {
            best = other;
            best_gap = gap;
        }
    }

    return best;
}
