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
const rules = @import("layouts/rules.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Workspace = @import("Workspace.zig");

const log = std.log.scoped(.window);

const Window = @This();

obj: *river.WindowV1,
node: *river.NodeV1,
link: wl.list.Link,
workspace_link: wl.list.Link,

new: bool = true,
closed: bool = false,

workspace: ?*Workspace = null,
parent: ?*Window = null,

x: i32 = 0,
y: i32 = 0,
width: i32 = 0,
height: i32 = 0,

slot: geom.Rect = geom.Rect.zero,
branch: ?*Eddy.Branch = null,
limits: rules.Limits = .{},

placed: ?geom.Point = null,
proposed: geom.Size = geom.Size.zero,
tiled: ?rules.Edges = null,
decorated_focused: ?bool = null,
hidden: bool = false,
resizing: bool = false,
tiled_informed: ?bool = null,
floating: bool = false,
float_box: geom.Rect = geom.Rect.zero,

overshoot: geom.Size = geom.Size.zero,

focus_count: u8 = 0,

fullscreen: ?*Output = null,
fullscreen_applied: ?*Output = null,
fullscreen_request: FullscreenRequest = .none,
pointer_request: PointerRequest = .none,

pub const FullscreenRequest = union(enum) {
    none,
    enter: ?*Output,
    exit,
};

pub const PointerRequest = union(enum) {
    none,
    move: struct { seat: *Seat },
    resize: struct { seat: *Seat },
};

pub const border_focused = color.rgb(0x4c, 0x7a, 0x5d);
pub const border_inactive = color.rgb(0x50, 0x49, 0x45);

const max_overshoot = 64;

pub const capabilities: river.WindowV1.Capabilities = .{
    .window_menu = false,
    .maximize = false,
    .minimize = false,
    .fullscreen = true,
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

    const at: geom.Point = .{ .x = origin.x + window.x, .y = origin.y + window.y };
    if (window.placed) |last| {
        if (last.eql(at)) return;
    }

    window.node.setPosition(at.x, at.y);
    window.placed = at;
}

pub fn applyPlacement(window: *Window, p: rules.Placement) void {
    if (window.floating) return;

    window.apply(p);
}

pub fn applyFloating(window: *Window, area: geom.Rect) void {
    if (window.float_box.width == 0) {
        if (!window.sized()) {
            window.propose(geom.Size.zero);
            return;
        }

        window.float_box = .{
            .x = area.x + @divTrunc(area.width - window.width, 2),
            .y = area.y + @divTrunc(area.height - window.height, 2),
            .width = window.width,
            .height = window.height,
        };
    }

    window.apply(rules.placeFloating(window.float_box, area, window.limits));
}

fn apply(window: *Window, p: rules.Placement) void {
    if (window.fullscreen != null) return;

    window.syncTiled(!window.floating);

    if (!p.content.size().eql(window.slot.size())) {
        window.overshoot = geom.Size.zero;
        window.propose(p.content.size());
        window.obj.setContentClipBox(0, 0, p.content.width, p.content.height);
    }

    window.slot = p.content;
    window.setPosition(p.content.x, p.content.y);
}

fn propose(window: *Window, size: geom.Size) void {
    window.proposed = size;
    window.obj.proposeDimensions(size.width, size.height);
}

fn syncTiled(window: *Window, on: bool) void {
    if (window.tiled_informed) |applied| {
        if (applied == on) return;
    }

    window.obj.setTiled(if (on) .{
        .top = true,
        .bottom = true,
        .left = true,
        .right = true,
    } else .{
        .top = false,
        .bottom = false,
        .left = false,
        .right = false,
    });
    window.tiled_informed = on;
}

fn currentOutput(window: *Window) ?*Output {
    const ws = window.workspace orelse return null;
    return ws.output;
}

pub fn toggleFullscreen(window: *Window) void {
    window.fullscreen = if (window.fullscreen != null) null else window.currentOutput();
}

fn syncFullscreen(window: *Window) void {
    if (window.fullscreen == window.fullscreen_applied) return;

    if (window.fullscreen) |output| {
        window.obj.fullscreen(output.obj);
        window.obj.informFullscreen();
        window.node.placeTop();
    } else {
        window.obj.exitFullscreen();
        window.obj.informNotFullscreen();

        window.slot = geom.Rect.zero;
        window.placed = null;
    }

    window.fullscreen_applied = window.fullscreen;
}

pub fn toggleFloating(window: *Window) void {
    window.setFloating(!window.floating);
}

pub fn setFloating(window: *Window, on: bool) void {
    if (window.floating == on) return;
    window.floating = on;

    const ws = window.workspace orelse return;

    if (on) {
        ws.layout.remove(window);

        if (window.float_box.width == 0 and window.sized()) {
            window.float_box = .{
                .x = window.slot.x,
                .y = window.slot.y,
                .width = window.width,
                .height = window.height,
            };
        }
    } else {
        window.float_box = window.slot;

        const near = if (ws.cursor()) |c| ws.layout.windowAt(c) else null;
        ws.layout.insert(window, near, ws.cursor());
    }

    ws.raiseFloating();
}

pub fn moveFloating(window: *Window, dx: i32, dy: i32) void {
    window.float_box.x += dx;
    window.float_box.y += dy;
}

pub fn resizeFloating(window: *Window, dx: i32, dy: i32) void {
    window.float_box.width = @max(1, window.float_box.width + dx);
    window.float_box.height = @max(1, window.float_box.height + dy);
}

fn syncResizing(window: *Window) void {
    var want = false;
    var seats = wm.seats.iterator(.forward);
    while (seats.next()) |seat| {
        switch (seat.op) {
            .resize => |args| if (args.window == window) {
                want = true;
            },
            else => {},
        }
    }

    if (want == window.resizing) return;

    if (want) window.obj.informResizeStart() else window.obj.informResizeEnd();
    window.resizing = want;

    log.debug("resize {s}", .{if (want) "start" else "end"});
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

fn syncSize(window: *Window) void {
    if (window.slot.width == 0 or !window.sized()) return;

    const short_w = @max(0, window.slot.width - window.width);
    const short_h = @max(0, window.slot.height - window.height);
    if (short_w == 0 and short_h == 0) return;
    if (short_w > max_overshoot or short_h > max_overshoot) {
        log.debug("giving up: slot {d}x{d} actual {d}x{d}", .{
            window.slot.width, window.slot.height, window.width, window.height,
        });
        return;
    }

    if (short_w > 0) {
        window.overshoot.width = @min(max_overshoot, @max(window.overshoot.width * 2, short_w));
    }
    if (short_h > 0) {
        window.overshoot.height = @min(max_overshoot, @max(window.overshoot.height * 2, short_h));
    }

    const want: geom.Size = .{
        .width = window.slot.width + window.overshoot.width,
        .height = window.slot.height + window.overshoot.height,
    };

    if (want.width == window.proposed.width and want.height == window.proposed.height) return;

    window.obj.proposeDimensions(want.width, want.height);
    window.proposed = want;
}

pub fn center(window: *Window) void {
    if (window.slot.width == 0 or !window.sized()) return;

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
        rules.border_width,
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
        if (window.parent != null) window.setFloating(true);
    }

    switch (window.pointer_request) {
        .none => {},
        .move => |args| if (window.visible()) args.seat.pointerMove(window),
        .resize => |args| if (window.visible()) args.seat.pointerResize(window),
    }
    window.pointer_request = .none;

    switch (window.fullscreen_request) {
        .none => {},
        .enter => |hint| window.fullscreen = hint orelse window.currentOutput(),
        .exit => window.fullscreen = null,
    }
    window.fullscreen_request = .none;

    window.syncFullscreen();
    window.syncResizing();
    window.syncDecoration();
    window.syncVisibility();

    if (window.fullscreen != null) return;

    window.syncSize();
    window.syncPosition();
}

fn listener(_: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
    switch (event) {
        .closed => window.closed = true,
        .dimensions_hint => |args| window.limits = .{
            .min = .{ .width = args.min_width, .height = args.min_height },
            .max = .{ .width = args.max_width, .height = args.max_height },
        },
        .dimensions => |args| {
            window.width = args.width;
            window.height = args.height;
        },
        .fullscreen_requested => |args| window.fullscreen_request = .{
            .enter = if (args.output) |o| Output.fromObj(o) else null,
        },
        .exit_fullscreen_requested => window.fullscreen_request = .exit,
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
