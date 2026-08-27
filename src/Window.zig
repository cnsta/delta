const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const color = @import("util/color.zig");
const geom = @import("util/geom.zig");
const list = @import("util/list.zig");

const Eddy = @import("layouts/Eddy.zig");

const Seat = @import("Seat.zig");
const Workspace = @import("Workspace.zig");

const Window = @This();

obj: *river.WindowV1,
node: *river.NodeV1,
link: wl.list.Link,
workspace_link: wl.list.Link,
new: bool = true,
closed: bool = false,
branch: ?*Eddy.Branch = null,
slot: geom.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
focus_count: u8 = 0,
decorated_focused: ?bool = null,
parent: ?*Window = null,
hidden: bool = false,
workspace: ?*Workspace = null,

x: i32 = 0,
y: i32 = 0,
width: i32 = 0,
height: i32 = 0,

pointer_request: PointerRequest = .none,

pub const PointerRequest = union(enum) {
    none,
    move: struct { seat: *Seat },
    resize: struct { seat: *Seat },
};

pub const border_width = 2;
pub const border_focused = color.rgb(0x7a, 0xa2, 0xf7);
pub const border_inactive = color.rgb(0x41, 0x48, 0x68);

pub const capabilities: river.WindowV1.Capabilities = .{
    .window_menu = false,
    .maximize = false,
    .minimize = false,
    .fullscreen = false,
};

pub fn create(river_window: *river.WindowV1) void {
    const window = wm.gpa.create(Window) catch fatal("Out of memory.", .{});
    window.* = .{
        .obj = river_window,
        .node = river_window.getNode() catch fatal("Unable to obtain Window's Node.", .{}),
        .link = undefined,
        .workspace_link = undefined,
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

    var others = list.safeIterator(Window, .link, &wm.windows);
    while (others.next()) |other| {
        if (other.parent == window) other.parent = null;
    }

    if (window.workspace) |ws| {
        ws.layout.remove(window);
        window.workspace_link.remove();
        window.workspace = null;
    }

    window.obj.destroy();
    window.link.remove();
    wm.gpa.destroy(window);
}

fn initialWorkspace(window: *Window) *Workspace {
    if (window.parent) |parent| {
        if (parent.workspace) |ws| return ws;
    }
    return Workspace.forNewWindow();
}

pub fn setWorkspace(window: *Window, target: *Workspace) void {
    if (window.workspace == target) return;

    if (window.workspace) |old| {
        old.layout.remove(window);
        window.workspace_link.remove();
    }

    const near = target.windows.last();

    window.workspace = target;
    target.windows.append(window);
    target.layout.insert(window, near, target.cursor());
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

pub fn sized(window: *const Window) bool {
    return window.width > 0 and window.height > 0;
}

pub fn center(window: *Window) void {
    if (window.slot.width == 0) return;

    if (!window.sized()) {
        window.setPosition(window.slot.x, window.slot.y);
        return;
    }

    window.setPosition(
        window.slot.x + @max(0, @divTrunc(window.slot.width - window.width, 2)),
        window.slot.y + @max(0, @divTrunc(window.slot.height - window.height, 2)),
    );
}

pub fn focused(window: *const Window) bool {
    return window.focus_count > 0;
}

pub fn syncDecoration(window: *Window) void {
    const is_focused = window.focused();
    if (window.decorated_focused) |applied| {
        if (applied == is_focused) return;
    }

    const c = if (is_focused) border_focused else border_inactive;
    window.obj.setBorders(
        .{ .top = true, .bottom = true, .left = true, .right = true },
        border_width,
        c.r,
        c.g,
        c.b,
        c.a,
    );
    window.decorated_focused = is_focused;
}

pub fn visible(window: *const Window) bool {
    const ws = window.workspace orelse return false;
    return ws.visible();
}

pub fn manage(window: *Window) void {
    if (window.new) {
        window.new = false;

        window.obj.setCapabilities(capabilities);
        window.obj.useSsd();

        window.setWorkspace(window.initialWorkspace());
    }

    switch (window.pointer_request) {
        .none => {},
        .move => |args| if (window.visible()) args.seat.pointerMove(window),
        .resize => |args| if (window.visible()) args.seat.pointerResize(window),
    }
    window.pointer_request = .none;

    window.syncDecoration();
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
        .parent => |args| window.parent = if (args.parent) |p| fromObj(p) else null,
        .pointer_move_requested => |args| if (args.seat) |seat| {
            window.pointer_request = .{ .move = .{
                .seat = Seat.fromObj(seat),
            } };
        },
        .pointer_resize_requested => |args| if (args.seat) |seat| {
            window.pointer_request = .{ .resize = .{
                .seat = Seat.fromObj(seat),
            } };
        },
        else => {},
    }
}
