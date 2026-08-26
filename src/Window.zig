const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const list = @import("util/list.zig");

const Seat = @import("Seat.zig");
const Workspace = @import("Workspace.zig");

const Window = @This();

obj: *river.WindowV1,
node: *river.NodeV1,

link: wl.list.Link,
workspace_link: wl.list.Link,

new: bool = true,
closed: bool = false,

hidden: bool = false,

workspace: ?*Workspace = null,

x: i32 = 0,
y: i32 = 0,
width: i32,
height: i32,

pointer_request: PointerRequest = .none,

pub const PointerRequest = union(enum) {
    none,
    move: struct { seat: *Seat },
    resize: struct { seat: *Seat, edges: river.WindowV1.Edges },
};

pub fn create(river_window: *river.WindowV1) void {
    const window = wm.gpa.create(Window) catch fatal("Out of memory.", .{});
    window.* = .{
        .obj = river_window,
        .node = river_window.getNode() catch fatal("Unable to obtain Window's Node.", .{}),
        .link = undefined,
        .workspace_link = undefined,
        .width = undefined,
        .height = undefined,
    };
    window.obj.setListener(*Window, listener, window);
    wm.windows.append(window);
}

pub fn fromObj(obj: *river.WindowV1) *Window {
    return @ptrCast(@alignCast(obj.getUserData()));
}

pub fn maybeDestroy(window: *Window) void {
    if (!window.closed) return;

    var seats = list.safeIterator(Seat, .link, &wm.seats);
    while (seats.next()) |seat| seat.forgetWindow(window);

    if (window.workspace != null) {
        window.workspace_link.remove();
        window.workspace = null;
    }

    window.obj.destroy();
    window.link.remove();
    wm.gpa.destroy(window);
}

pub fn setWorkspace(window: *Window, target: *Workspace) void {
    if (window.workspace == target) return;

    if (window.workspace != null) window.workspace_link.remove();
    window.workspace = target;
    target.windows.append(window);
}

pub fn setPosition(window: *Window, x: i32, y: i32) void {
    window.x = x;
    window.y = y;
    window.syncPosition();
}

pub fn syncPosition(window: *Window) void {
    const ws = window.workspace orelse return;
    const origin = ws.origin() orelse return;
    window.node.setPosition(origin.x + window.x, origin.y + window.y);
}

pub fn syncVisibility(window: *Window) void {
    const want_hidden = !window.visible();
    if (want_hidden == window.hidden) return;

    if (want_hidden) window.obj.hide() else window.obj.show();
    window.hidden = want_hidden;
}

pub fn visible(window: *const Window) bool {
    const ws = window.workspace orelse return false;
    return ws.visible();
}

pub fn manage(window: *Window) void {
    if (window.new) {
        window.new = false;
        window.setWorkspace(Workspace.forNewWindow());
        window.setPosition(0, 0);
        window.obj.proposeDimensions(0, 0);
    }

    switch (window.pointer_request) {
        .none => {},
        .move => |args| if (window.visible()) args.seat.pointerMove(window),
        .resize => |args| if (window.visible()) args.seat.pointerResize(window, args.edges),
    }
    window.pointer_request = .none;

    window.syncVisibility();
    window.syncPosition();
}

fn listener(_: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
    switch (event) {
        .closed => window.closed = true,
        .dimensions => |args| {
            window.width = args.width;
            window.height = args.height;
        },
        .pointer_move_requested => |args| if (args.seat) |seat| {
            window.pointer_request = .{ .move = .{
                .seat = Seat.fromObj(seat),
            } };
        },
        .pointer_resize_requested => |args| if (args.seat) |seat| {
            window.pointer_request = .{ .resize = .{
                .seat = Seat.fromObj(seat),
                .edges = args.edges,
            } };
        },
        else => {},
    }
}
