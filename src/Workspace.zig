const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const geom = @import("util/geom.zig");

const Eddy = @import("layouts/Eddy.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");

const Workspace = @This();

pub const Id = u32;

id: Id,

link: wl.list.Link,

output: ?*Output = null,

windows: wl.list.Head(Window, .workspace_link),

layout: Eddy = .{},

pub fn get(id: Id) *Workspace {
    var it = wm.workspaces.iterator(.forward);
    while (it.next()) |ws| {
        if (ws.id == id) return ws;
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

pub fn forNewWindow() *Workspace {
    if (wm.seats.first()) |seat| {
        if (seat.output) |output| return output.workspace;
    }
    if (wm.outputs.first()) |output| return output.workspace;
    return get(1);
}

pub fn maybeDestroy(ws: *Workspace) void {
    if (ws.output != null) return;
    if (!ws.isEmpty()) return;

    std.debug.assert(ws.layout.isEmpty());

    ws.link.remove();
    wm.gpa.destroy(ws);
}

pub fn isEmpty(ws: *const Workspace) bool {
    return ws.windows.empty();
}

pub fn cursor(ws: *Workspace) ?geom.Point {
    const origin = ws.origin() orelse return null;
    const seat = wm.seats.first() orelse return null;
    if (!seat.pointer_known) return null;

    return .{
        .x = seat.pointer.x - origin.x,
        .y = seat.pointer.y - origin.y,
    };
}

pub fn visible(ws: *const Workspace) bool {
    return ws.output != null;
}

pub fn origin(ws: *const Workspace) ?geom.Point {
    const output = ws.output orelse return null;
    return .{ .x = output.x, .y = output.y };
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
    return ws;
}
