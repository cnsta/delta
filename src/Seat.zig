const std = @import("std");
const wayland = @import("wayland");
const xkb = @import("xkbcommon");
const event_codes = @import("event-codes");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const geom = @import("util/geom.zig");

const Action = @import("input/action.zig").Action;
const Eddy = @import("layouts/Eddy.zig");
const rules = @import("layouts/rules.zig");
const Output = @import("Output.zig");
const PointerBinding = @import("input/PointerBinding.zig");
const Window = @import("Window.zig");
const Workspace = @import("Workspace.zig");
const XkbBinding = @import("input/XkbBinding.zig");

const Seat = @This();

obj: *river.SeatV1,
removed: bool = false,
link: wl.list.Link,

focused: ?*Window = null,
hovered: ?*Window = null,
interacted: ?*Window = null,
warp_to: ?*Window = null,

xkb_bindings: wl.list.Head(XkbBinding, .link),
pointer_bindings: wl.list.Head(PointerBinding, .link),
pending_action: Action = .none,

op: Op = .none,
op_dx: i32 = 0,
op_dy: i32 = 0,
op_release: bool = false,

shell: ?*river.LayerShellSeatV1 = null,

layer_focus: LayerFocus = .none,

pointer: geom.Point = geom.Point.zero,
pointer_known: bool = false,

output: ?*Output = null,

pub const warp_on_focus = true;

pub const LayerFocus = enum { none, non_exclusive, exclusive };

pub const Op = union(enum) {
    none,
    move: struct { window: *Window },
    resize: struct {
        window: *Window,
        applied_dx: i32 = 0,
        applied_dy: i32 = 0,
    },
};

pub fn create(river_seat: *river.SeatV1) void {
    const seat = wm.gpa.create(Seat) catch fatal("Out of memory.", .{});
    seat.* = .{
        .obj = river_seat,
        .link = undefined,
        .xkb_bindings = undefined,
        .pointer_bindings = undefined,
    };
    seat.xkb_bindings.init();
    seat.pointer_bindings.init();
    seat.obj.setListener(*Seat, listener, seat);
    wm.seats.append(seat);

    if (wm.layer_shell) |layer_shell| {
        const shell = layer_shell.getSeat(river_seat) catch fatal("Out of memory.", .{});
        seat.shell = shell;
        shell.setListener(*Seat, shellListener, seat);
    }

    seat.setupDefaultBindings();
    std.log.info("seat ready, {d} key bindings, {d} pointer bindings", .{
        seat.xkb_bindings.length(), seat.pointer_bindings.length(),
    });
}

pub fn fromObj(obj: *river.SeatV1) *Seat {
    return @ptrCast(@alignCast(obj.getUserData()));
}

pub fn maybeDestroy(seat: *Seat) void {
    if (!seat.removed) return;

    while (seat.xkb_bindings.first()) |binding| binding.destroy();
    while (seat.pointer_bindings.first()) |binding| binding.destroy();

    if (seat.shell) |shell| shell.destroy();

    seat.obj.destroy();
    seat.link.remove();
    wm.gpa.destroy(seat);
}

pub fn forgetWindow(seat: *Seat, window: *Window) void {
    if (seat.focused == window) {
        window.focus_count -= 1;
        seat.focused = null;
    }
    if (seat.hovered == window) seat.hovered = null;
    if (seat.interacted == window) seat.interacted = null;

    switch (seat.op) {
        .none => {},
        inline .move, .resize => |args| if (args.window == window) {
            seat.obj.opEnd();
            seat.op = .none;
        },
    }
}

pub fn forgetOutput(seat: *Seat, output_gone: *Output) void {
    if (seat.output == output_gone) seat.output = null;
}

pub fn workspace(seat: *Seat) ?*Workspace {
    if (seat.focused) |w| {
        if (w.workspace) |ws| return ws;
    }
    const o = seat.output orelse return null;
    return o.workspace;
}

pub fn focus(seat: *Seat, window: ?*Window) void {
    const target = window orelse blk: {
        const ws = seat.workspace() orelse break :blk null;
        break :blk ws.windows.last();
    };

    if (seat.focused == target) return;

    if (seat.focused) |old| old.focus_count -= 1;

    if (target) |w| {
        seat.obj.focusWindow(w.obj);
        w.node.placeTop();

        w.link.remove();
        wm.windows.append(w);

        if (w.workspace) |ws| {
            w.workspace_link.remove();
            ws.windows.append(w);
        }

        w.focus_count += 1;
    } else {
        seat.obj.clearFocus();
    }

    seat.focused = target;
}

pub fn pointerMove(seat: *Seat, window: *Window) void {
    if (seat.op != .none) return;

    seat.focus(window);
    seat.obj.opStartPointer();
    seat.op = .{ .move = .{ .window = window } };
    seat.op_dx = 0;
    seat.op_dy = 0;
}

pub fn pointerResize(seat: *Seat, window: *Window) void {
    if (seat.op != .none) return;

    seat.focus(window);
    seat.obj.opStartPointer();
    seat.op = .{ .resize = .{ .window = window } };
    seat.op_dx = 0;
    seat.op_dy = 0;
}

pub fn closeFocused(seat: *Seat) void {
    const window = seat.focused orelse return;
    window.obj.close();
}

pub fn toggleFullscreen(seat: *Seat) void {
    const window = seat.focused orelse return;
    window.toggleFullscreen();
}

pub fn resizeStep(seat: *Seat, how: Action.Resize) void {
    const window = seat.focused orelse return;

    if (window.fullscreen != null) return;
    const step = rules.resize_step;

    switch (how) {
        .grow_width => Eddy.resize(window, step, 0),
        .shrink_width => Eddy.resize(window, -step, 0),
        .grow_height => Eddy.resize(window, 0, step),
        .shrink_height => Eddy.resize(window, 0, -step),
    }
}

pub fn startPointerMove(seat: *Seat) void {
    const window = seat.hovered orelse return;
    seat.pointerMove(window);
}

pub fn startPointerResize(seat: *Seat) void {
    const window = seat.hovered orelse return;
    seat.pointerResize(window);
}

pub fn focusWorkspace(seat: *Seat, id: Workspace.Id) void {
    const target = Workspace.get(id);

    if (target.output == null) {
        const o = seat.output orelse return;
        o.setWorkspace(target);
    }

    seat.dropFocus();
    seat.focus(target.windows.last());
    seat.warpTo(seat.focused);
}

pub fn sendToWorkspace(seat: *Seat, id: Workspace.Id) void {
    const window = seat.focused orelse return;
    const target = Workspace.get(id);
    if (window.workspace == target) return;

    window.setWorkspace(target);

    seat.dropFocus();
    seat.focus(null);
    seat.warpTo(seat.focused);
}

pub fn manage(seat: *Seat) void {
    seat.syncBindings(!wm.locked);

    seat.updateOutput();

    if (wm.locked) {
        seat.endOp();
        seat.interacted = null;
        seat.pending_action = .none;
        seat.op_release = false;
        return;
    }

    switch (seat.layer_focus) {
        .exclusive => seat.dropFocus(),
        .non_exclusive => if (seat.interacted) |w| seat.focus(w) else seat.dropFocus(),
        .none => seat.focus(seat.interacted),
    }
    seat.interacted = null;

    seat.pending_action.execute(seat);
    seat.pending_action = .none;

    if (seat.op_release) {
        switch (seat.op) {
            .none => {},
            .move => |args| seat.dropMove(args.window),
            .resize => {},
        }
        seat.endOp();
    } else switch (seat.op) {
        .none, .move => {},
        .resize => |*args| {
            Eddy.resize(
                args.window,
                seat.op_dx - args.applied_dx,
                seat.op_dy - args.applied_dy,
            );
            args.applied_dx = seat.op_dx;
            args.applied_dy = seat.op_dy;
        },
    }

    seat.op_release = false;
}

pub fn applyWarp(seat: *Seat) void {
    const window = seat.warp_to orelse return;
    seat.warp_to = null;

    if (seat.op != .none) return;
    if (!window.visible()) return;

    const ws = window.workspace orelse return;
    const topleft = ws.origin() orelse return;

    if (!warp_on_focus) {
        seat.output = ws.output;
        return;
    }

    const x = topleft.x + window.slot.x + @divTrunc(window.slot.width, 2);
    const y = topleft.y + window.slot.y + @divTrunc(window.slot.height, 2);
    seat.obj.pointerWarp(x, y);
    seat.pointer = .{ .x = x, .y = y };
    seat.pointer_known = true;
    seat.output = ws.output;
}

pub fn focusNext(seat: *Seat) void {
    const ws = seat.workspace() orelse return;
    seat.focus(ws.windows.first());
    seat.warpTo(seat.focused);
}

pub fn focusDirection(seat: *Seat, dir: geom.Direction) void {
    const window = seat.focused orelse {
        seat.focus(null);
        seat.warpTo(seat.focused);
        return;
    };
    const ws = window.workspace orelse return;

    if (ws.windowInDirection(window, dir)) |target| {
        seat.focus(target);
        seat.warpTo(seat.focused);
    }
}

fn syncBindings(seat: *Seat, on: bool) void {
    var keys = seat.xkb_bindings.iterator(.forward);
    while (keys.next()) |binding| binding.setEnabled(on);

    var buttons = seat.pointer_bindings.iterator(.forward);
    while (buttons.next()) |binding| binding.setEnabled(on);
}

fn endOp(seat: *Seat) void {
    if (seat.op == .none) return;

    seat.obj.opEnd();
    seat.op = .none;
}

fn dropMove(seat: *Seat, window: *Window) void {
    if (!seat.pointer_known) return;
    const ws = window.workspace orelse return;
    const origin = ws.origin() orelse return;

    const point: geom.Point = .{
        .x = seat.pointer.x - origin.x,
        .y = seat.pointer.y - origin.y,
    };
    const other = ws.layout.windowAt(point) orelse return;
    ws.layout.swap(window, other);
}

/// Hardcoded for now.
fn setupDefaultBindings(seat: *Seat) void {
    const super: river.SeatV1.Modifiers = .{ .mod4 = true };
    const super_shift: river.SeatV1.Modifiers = .{ .mod4 = true, .shift = true };

    XkbBinding.create(seat, super, .t, .{ .spawn = &.{"ghostty"} });
    XkbBinding.create(seat, super, .space, .{ .spawn = &.{"fuzzel"} });
    XkbBinding.create(seat, super, .w, .{ .spawn = &.{"zen"} });
    XkbBinding.create(seat, super_shift, .w, .{ .spawn = &.{ "zen", "--private-window" } });
    XkbBinding.create(seat, super, .e, .{ .spawn = &.{"nautilus"} });
    XkbBinding.create(seat, super_shift, .l, .{ .spawn = &.{"waylock"} });
    XkbBinding.create(seat, super, .i, .{ .spawn = &.{"byt"} });

    XkbBinding.create(seat, super, .q, .close);
    XkbBinding.create(seat, super, .f, .toggle_fullscreen);
    XkbBinding.create(seat, super, .n, .focus_next);

    const arrows = [4]u32{ 0xff51, 0xff53, 0xff52, 0xff54 };
    const letters = [4]xkb.Keysym{ .h, .l, .k, .j };
    const dirs = [4]geom.Direction{ .left, .right, .up, .down };

    inline for (arrows, letters, dirs) |arrow, letter, dir| {
        const key: xkb.Keysym = @enumFromInt(arrow);

        XkbBinding.create(seat, super, key, .{ .focus_direction = dir });
        XkbBinding.create(seat, super, letter, .{ .focus_direction = dir });
    }

    const question: xkb.Keysym = @enumFromInt(0x03f);
    const minus: xkb.Keysym = @enumFromInt(0x02d);
    const plus: xkb.Keysym = @enumFromInt(0x02b);
    const underscore: xkb.Keysym = @enumFromInt(0x05f);
    const kp_add: xkb.Keysym = @enumFromInt(0xffab);
    const kp_subtract: xkb.Keysym = @enumFromInt(0xffad);

    XkbBinding.create(seat, super, question, .{ .resize = .grow_width });
    XkbBinding.create(seat, super, plus, .{ .resize = .grow_width });

    XkbBinding.create(seat, super, minus, .{ .resize = .shrink_width });
    XkbBinding.create(seat, super, underscore, .{ .resize = .shrink_width });

    XkbBinding.create(seat, super, kp_add, .{ .resize = .grow_width });
    XkbBinding.create(seat, super, kp_subtract, .{ .resize = .shrink_width });

    XkbBinding.create(seat, super_shift, plus, .{ .resize = .grow_height });
    XkbBinding.create(seat, super_shift, question, .{ .resize = .grow_height });
    XkbBinding.create(seat, super_shift, underscore, .{ .resize = .shrink_height });
    XkbBinding.create(seat, super_shift, minus, .{ .resize = .shrink_height });
    XkbBinding.create(seat, super_shift, kp_add, .{ .resize = .grow_height });
    XkbBinding.create(seat, super_shift, kp_subtract, .{ .resize = .shrink_height });

    XkbBinding.create(seat, super, .Escape, .exit);

    inline for (1..10) |n| {
        const keysym: xkb.Keysym = @enumFromInt('0' + n);
        XkbBinding.create(seat, super, keysym, .{ .focus_workspace = n });
        XkbBinding.create(seat, super_shift, keysym, .{ .send_to_workspace = n });
    }

    PointerBinding.create(seat, super, event_codes.BTN_LEFT, .pointer_move);
    PointerBinding.create(seat, super, event_codes.BTN_RIGHT, .pointer_resize);
}

fn shellListener(
    _: *river.LayerShellSeatV1,
    event: river.LayerShellSeatV1.Event,
    seat: *Seat,
) void {
    switch (event) {
        .focus_exclusive => seat.layer_focus = .exclusive,
        .focus_non_exclusive => seat.layer_focus = .non_exclusive,
        .focus_none => seat.layer_focus = .none,
    }
}

fn listener(_: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    switch (event) {
        .removed => seat.removed = true,
        .pointer_enter => |args| {
            seat.hovered = if (args.window) |w| Window.fromObj(w) else null;

            seat.interacted = seat.hovered;
        },
        .pointer_leave => seat.hovered = null,
        .window_interaction => |args| seat.interacted = if (args.window) |w| Window.fromObj(w) else null,
        .op_delta => |args| {
            seat.op_dx = args.dx;
            seat.op_dy = args.dy;
        },
        .op_release => seat.op_release = true,

        .pointer_position => |args| {
            seat.pointer = .{ .x = args.x, .y = args.y };
            seat.pointer_known = true;
        },

        else => {},
    }
}

fn updateOutput(seat: *Seat) void {
    if (seat.pointer_known) {
        if (Output.at(seat.pointer)) |o| {
            seat.output = o;
            return;
        }
    }

    if (seat.focused) |w| {
        if (w.workspace) |ws| {
            if (ws.output) |o| {
                seat.output = o;
                return;
            }
        }
    }

    if (seat.output != null) return;

    seat.output = wm.outputs.first();
}

fn warpTo(seat: *Seat, window: ?*Window) void {
    if (window) |w| seat.warp_to = w;
}

fn dropFocus(seat: *Seat) void {
    const old = seat.focused orelse return;
    old.focus_count -= 1;
    seat.focused = null;
}
