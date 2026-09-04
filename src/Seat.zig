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
const Config = @import("Config.zig");

const Seat = @This();
const log = std.log.scoped(.seat);

obj: *river.SeatV1,
removed: bool = false,
link: wl.list.Link,

focused: ?*Window = null,
hovered: ?*Window = null,
interacted: ?*Window = null,
warp_to: ?*Window = null,

xkb_bindings: wl.list.Head(XkbBinding, .link),
pointer_bindings: wl.list.Head(PointerBinding, .link),
pending: Action.Queue = .{},

repeat_binding: ?*XkbBinding = null,

repeat_at: i64 = 0,

op: Op = .none,
op_dx: i32 = 0,
op_dy: i32 = 0,
op_release: bool = false,

shell: ?*river.LayerShellSeatV1 = null,

layer_focus: LayerFocus = .none,

pointer: geom.Point = geom.Point.zero,
pointer_known: bool = false,

output: ?*Output = null,

pub const LayerFocus = enum { none, non_exclusive, exclusive };

pub const Op = union(enum) {
    none,
    move: struct {
        window: *Window,
        applied_dx: i32 = 0,
        applied_dy: i32 = 0,
        dragging: bool = false,
    },
    resize: struct {
        window: *Window,
        applied_dx: i32 = 0,
        applied_dy: i32 = 0,
    },
};

// -- lifecycle ---------------------------------------------------------

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

    seat.setupBindings();
}

pub fn fromObj(obj: *river.SeatV1) *Seat {
    return @ptrCast(@alignCast(obj.getUserData()));
}

pub fn maybeDestroy(seat: *Seat) void {
    if (!seat.removed) return;

    seat.repeat_binding = null;
    seat.pending.clear();

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

// -- queries -----------------------------------------------------------

pub fn workspace(seat: *Seat) ?*Workspace {
    if (seat.focused) |w| {
        if (w.workspace) |ws| return ws;
    }
    const o = seat.output orelse return null;
    return o.workspace;
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

pub fn repeatDeadline(seat: *const Seat) ?i64 {
    if (seat.repeat_binding == null) return null;
    return seat.repeat_at;
}

// -- the manage sequence -----------------------------------------------

pub fn manage(seat: *Seat) void {
    if (wm.locked_applied != wm.locked) seat.syncBindings(!wm.locked);

    seat.updateOutput();

    if (wm.locked) {
        seat.endOp();
        seat.interacted = null;
        seat.pending.clear();
        seat.repeat_binding = null;
        seat.op_release = false;
        return;
    }

    switch (seat.layer_focus) {
        .exclusive => seat.dropFocus(),
        .non_exclusive => if (seat.interacted) |w| {
            _ = seat.focus(w);
        } else seat.dropFocus(),
        .none => _ = seat.focus(seat.interacted),
    }
    seat.interacted = null;

    while (seat.pending.pop()) |action| action.execute(seat);

    if (seat.op_release) {
        switch (seat.op) {
            .none => {},
            .move => |args| if (!args.window.floating and args.dragging) seat.dropMove(args.window),
            .resize => {},
        }
        seat.endOp();
    } else switch (seat.op) {
        .none => {},
        .move => |*args| {
            if (!args.dragging) {
                const t = wm.config.input.drag_threshold;
                if (seat.op_dx * seat.op_dx + seat.op_dy * seat.op_dy < t * t) return;
                args.dragging = true;
            }

            if (args.window.floating) {
                args.window.moveFloating(
                    seat.op_dx - args.applied_dx,
                    seat.op_dy - args.applied_dy,
                );
                args.applied_dx = seat.op_dx;
                args.applied_dy = seat.op_dy;
            }
        },

        .resize => |*args| {
            const dx = seat.op_dx - args.applied_dx;
            const dy = seat.op_dy - args.applied_dy;

            // A floating window resizes itself; a tiled one moves a divider.
            if (args.window.floating) {
                args.window.resizeFloating(dx, dy);
            } else {
                Eddy.resize(args.window, dx, dy);
            }

            args.applied_dx = seat.op_dx;
            args.applied_dy = seat.op_dy;
        },
    }

    seat.op_release = false;
}

fn syncBindings(seat: *Seat, on: bool) void {
    var keys = seat.xkb_bindings.iterator(.forward);
    while (keys.next()) |binding| binding.setEnabled(on);

    var buttons = seat.pointer_bindings.iterator(.forward);
    while (buttons.next()) |binding| binding.setEnabled(on);
}

pub fn applyWarp(seat: *Seat) void {
    const window = seat.warp_to orelse return;
    seat.warp_to = null;

    if (seat.op != .none) return;
    if (!window.visible()) return;

    const ws = window.workspace orelse return;
    const topleft = ws.origin() orelse return;

    if (!warpOnFocus()) {
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

    const hit = ws.layout.tileAt(point) orelse return;
    ws.layout.dropOnto(window, hit.window, hit.rect, point);
}

pub fn tick(seat: *Seat, now: i64) void {
    const binding = seat.repeat_binding orelse return;
    if (now < seat.repeat_at) return;

    if (wm.locked) {
        seat.repeat_binding = null;
        return;
    }

    _ = seat.pending.push(binding.action);

    seat.repeat_at = now + wm.config.input.repeat_rate_ms;
    wm.dirty = true;
}

// -- focus -------------------------------------------------------------

pub fn focus(seat: *Seat, window: ?*Window) bool {
    const target = window orelse blk: {
        const ws = seat.workspace() orelse break :blk null;
        break :blk ws.windows.last();
    };

    if (seat.focused == target) return false;

    if (seat.focused) |old| old.focus_count -= 1;

    if (target) |w| {
        seat.obj.focusWindow(w.obj);
        w.node.placeTop();
        if (w.workspace) |ws| ws.raiseFloating();

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
    wm.ipc_dirty = true;
    return true;
}

pub fn dropFocus(seat: *Seat) void {
    const old = seat.focused orelse return;
    old.focus_count -= 1;
    seat.focused = null;
    wm.ipc_dirty = true;
}

pub fn warpTo(seat: *Seat, window: ?*Window) void {
    if (window) |w| seat.warp_to = w;
}

pub fn focusNext(seat: *Seat) void {
    const ws = seat.workspace() orelse return;
    if (seat.focus(ws.windows.first())) seat.warpTo(seat.focused);
}

pub fn focusDirection(seat: *Seat, dir: geom.Direction) void {
    const window = seat.focused orelse {
        if (seat.focus(null)) seat.warpTo(seat.focused);
        return;
    };
    const ws = window.workspace orelse return;

    if (ws.windowInDirection(window, dir)) |target| {
        if (seat.focus(target)) seat.warpTo(target);
    }
}

pub fn focusWorkspace(seat: *Seat, id: Workspace.Id) void {
    const target = Workspace.get(id);

    if (seat.workspace() == target) return;

    if (target.output == null) {
        const o = seat.output orelse return;
        o.setWorkspace(target);
    }

    seat.dropFocus();
    if (seat.focus(target.windows.last())) seat.warpTo(seat.focused);
}

pub fn sendToWorkspace(seat: *Seat, id: Workspace.Id) void {
    const window = seat.focused orelse return;
    const target = Workspace.get(id);
    if (window.workspace == target) return;

    window.setWorkspace(target);

    if (wm.config.input.follow_sent_windows) {
        seat.dropFocus();
        seat.focusWorkspace(id);
        return;
    }

    seat.dropFocus();
    if (seat.focus(null)) seat.warpTo(seat.focused);
}

// -- window actions ----------------------------------------------------

pub fn closeFocused(seat: *Seat) void {
    const window = seat.focused orelse return;
    window.obj.close();
}

pub fn toggleFullscreen(seat: *Seat) void {
    const window = seat.focused orelse return;
    window.toggleFullscreen();
}

pub fn toggleFloating(seat: *Seat) void {
    const window = seat.focused orelse return;

    if (window.fullscreen != null) return;

    window.toggleFloating();
}

pub fn resizeStep(seat: *Seat, how: Action.Resize) void {
    const window = seat.focused orelse return;

    if (window.fullscreen != null) return;
    const step = rules.resizeStep();

    if (window.floating) {
        switch (how) {
            .grow_width => window.resizeFloating(step, 0),
            .shrink_width => window.resizeFloating(-step, 0),
            .grow_height => window.resizeFloating(0, step),
            .shrink_height => window.resizeFloating(0, -step),
        }
        return;
    }

    switch (how) {
        .grow_width => Eddy.resize(window, step, 0),
        .shrink_width => Eddy.resize(window, -step, 0),
        .grow_height => Eddy.resize(window, 0, step),
        .shrink_height => Eddy.resize(window, 0, -step),
    }
}

// -- pointer operations ------------------------------------------------

pub fn startPointerMove(seat: *Seat) void {
    const window = seat.hovered orelse return;
    seat.pointerMove(window);
}

pub fn startPointerResize(seat: *Seat) void {
    const window = seat.hovered orelse return;
    seat.pointerResize(window);
}

pub fn pointerMove(seat: *Seat, window: *Window) void {
    if (seat.op != .none) return;

    _ = seat.focus(window);
    seat.obj.opStartPointer();
    seat.op = .{ .move = .{ .window = window } };
    seat.op_dx = 0;
    seat.op_dy = 0;
}

pub fn pointerResize(seat: *Seat, window: *Window) void {
    if (seat.op != .none) return;

    _ = seat.focus(window);
    seat.obj.opStartPointer();
    seat.op = .{ .resize = .{ .window = window } };
    seat.op_dx = 0;
    seat.op_dy = 0;
}

// -- key repeat --------------------------------------------------------

pub fn beginRepeat(seat: *Seat, binding: *XkbBinding) void {
    if (!binding.action.repeats()) return;

    seat.repeat_binding = binding;
    seat.repeat_at = wm.millis() + wm.config.input.repeat_delay_ms;
}

pub fn endRepeat(seat: *Seat, binding: *XkbBinding) void {
    if (seat.repeat_binding == binding) seat.repeat_binding = null;
}

// -- setup and listeners -----------------------------------------------

fn modifiers(mods: []const Config.Modifier) river.SeatV1.Modifiers {
    var result: river.SeatV1.Modifiers = .{};

    for (mods) |mod| switch (mod) {
        .shift => result.shift = true,
        .ctrl => result.ctrl = true,
        .alt => result.mod1 = true,
        .super => result.mod4 = true,
        .mod3 => result.mod3 = true,
        .mod5 => result.mod5 = true,
    };

    return result;
}

fn buttonCode(button: Config.PointerBinding.Button) u32 {
    return switch (button) {
        .left => event_codes.BTN_LEFT,
        .right => event_codes.BTN_RIGHT,
        .middle => event_codes.BTN_MIDDLE,
        .side => event_codes.BTN_SIDE,
        .extra => event_codes.BTN_EXTRA,
    };
}

pub fn warpOnFocus() bool {
    return wm.config.input.cursor.warp != .none;
}

pub fn warpOnSpawn() bool {
    return wm.config.input.cursor.warp == .spawn;
}

fn setupBindings(seat: *Seat) void {
    if (wm.config.bindings) |bindings| {
        for (bindings) |binding| {
            const mods = modifiers(binding.mods);

            for (binding.keys) |name| {
                const key = Config.keysym(name) orelse continue;
                XkbBinding.create(seat, mods, key, binding.action);
            }
        }
    } else {
        seat.setupDefaultKeyBindings();
    }

    if (wm.config.pointer_bindings) |bindings| {
        for (bindings) |binding| {
            PointerBinding.create(
                seat,
                modifiers(binding.mods),
                buttonCode(binding.button),
                binding.action,
            );
        }
    } else {
        seat.setupDefaultPointerBindings();
    }

    log.info("seat ready, {d} key bindings, {d} pointer bindings", .{
        seat.xkb_bindings.length(), seat.pointer_bindings.length(),
    });
}

pub fn reloadBindings(seat: *Seat) void {
    seat.repeat_binding = null;

    while (seat.xkb_bindings.first()) |binding| binding.destroy();
    while (seat.pointer_bindings.first()) |binding| binding.destroy();

    seat.setupBindings();
}

fn setupDefaultKeyBindings(seat: *Seat) void {
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
    XkbBinding.create(seat, super_shift, .f, .toggle_floating);
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
}

fn setupDefaultPointerBindings(seat: *Seat) void {
    const super: river.SeatV1.Modifiers = .{ .mod4 = true };

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

            if (wm.config.input.focus_follows_pointer) seat.interacted = seat.hovered;
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
        .wl_seat => {},
        .shell_surface_interaction => {},
    }
}
