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

xkb_bindings: wl.list.Head(XkbBinding, .link),
pointer_bindings: wl.list.Head(PointerBinding, .link),
pending_action: Action = .none,

op: Op = .none,
op_dx: i32 = 0,
op_dy: i32 = 0,
op_release: bool = false,

pointer: geom.Point = geom.Point.zero,
pointer_known: bool = false,

output: ?*Output = null,

pub const Op = union(enum) {
    none,
    move: struct {
        window: *Window,
        start_x: i32,
        start_y: i32,
    },
    resize: struct {
        window: *Window,
        start_x: i32,
        start_y: i32,
        start_width: i32,
        start_height: i32,
        edges: river.WindowV1.Edges = .{},
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
    seat.focus(window);
    seat.obj.opStartPointer();
    seat.op = .{ .move = .{
        .window = window,
        .start_x = window.x,
        .start_y = window.y,
    } };
    seat.op_dx = 0;
    seat.op_dy = 0;
}

pub fn pointerResize(seat: *Seat, window: *Window, edges: river.WindowV1.Edges) void {
    seat.focus(window);
    window.obj.informResizeStart();
    seat.obj.opStartPointer();
    seat.op = .{ .resize = .{
        .window = window,
        .start_x = window.x,
        .start_y = window.y,
        .start_width = window.width,
        .start_height = window.height,
        .edges = edges,
    } };
    seat.op_dx = 0;
    seat.op_dy = 0;
}

pub fn closeFocused(seat: *Seat) void {
    const window = seat.focused orelse return;
    window.obj.close();
}

pub fn focusNext(seat: *Seat) void {
    const ws = seat.workspace() orelse return;
    seat.focus(ws.windows.first());
}

pub fn startPointerMove(seat: *Seat) void {
    if (seat.op != .none) return;
    const window = seat.hovered orelse return;
    seat.pointerMove(window);
}

pub fn startPointerResize(seat: *Seat) void {
    if (seat.op != .none) return;
    const window = seat.hovered orelse return;
    seat.pointerResize(window, .{
        .top = false,
        .left = false,
        .right = true,
        .bottom = true,
    });
}

pub fn focusWorkspace(seat: *Seat, id: Workspace.Id) void {
    const target = Workspace.get(id);

    if (target.output == null) {
        const o = seat.output orelse return;
        o.setWorkspace(target);
    }

    seat.focused = null;
    seat.focus(target.windows.last());
}

pub fn sendToWorkspace(seat: *Seat, id: Workspace.Id) void {
    const window = seat.focused orelse return;
    const target = Workspace.get(id);
    if (window.workspace == target) return;

    window.setWorkspace(target);

    seat.focused = null;
    seat.focus(null);
}

fn syncBindings(seat: *Seat, on: bool) void {
    var keys = seat.xkb_bindings.iterator(.forward);
    while (keys.next()) |binding| binding.setEnabled(on);

    var buttons = seat.pointer_bindings.iterator(.forward);
    while (buttons.next()) |binding| binding.setEnabled(on);
}

fn endOp(seat: *Seat) void {
    switch (seat.op) {
        .none => return,
        .move => {},
        .resize => |args| args.window.obj.informResizeEnd(),
    }

    seat.obj.opEnd();
    seat.op = .none;
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

    seat.focus(seat.interacted);
    seat.interacted = null;

    seat.pending_action.execute(seat);
    seat.pending_action = .none;

    switch (seat.op) {
        .none => {},
        .move => if (seat.op_release) seat.endOp(),
        .resize => |args| {
            const window = args.window;
            if (seat.op_release) {
                seat.endOp();
            } else {
                var width = args.start_width;
                var height = args.start_height;
                if (args.edges.left) width -= seat.op_dx;
                if (args.edges.right) width += seat.op_dx;
                if (args.edges.top) height -= seat.op_dy;
                if (args.edges.bottom) height += seat.op_dy;
                window.obj.proposeDimensions(@max(1, width), @max(1, height));
            }
        },
    }

    seat.op_release = false;
}

pub fn render(seat: *Seat) void {
    switch (seat.op) {
        .none => {},
        .move => |args| args.window.setPosition(
            args.start_x + seat.op_dx,
            args.start_y + seat.op_dy,
        ),
        .resize => |args| {
            const window = args.window;
            var x = args.start_x;
            var y = args.start_y;
            if (args.edges.left) x += args.start_width - window.width;
            if (args.edges.top) y += args.start_height - window.height;
            window.setPosition(x, y);
        },
    }
}

/// Hardcoded for now.
fn setupDefaultBindings(seat: *Seat) void {
    const super: river.SeatV1.Modifiers = .{ .mod4 = true };
    const super_shift: river.SeatV1.Modifiers = .{ .mod4 = true, .shift = true };

    XkbBinding.create(seat, .{}, @enumFromInt(0xffc9), .{ .spawn = &.{"foot"} });

    XkbBinding.create(seat, super, .space, .{ .spawn = &.{"foot"} });
    XkbBinding.create(seat, super, .q, .close);
    XkbBinding.create(seat, super, .n, .focus_next);
    XkbBinding.create(seat, super, .Escape, .exit);

    inline for (1..10) |n| {
        const keysym: xkb.Keysym = @enumFromInt('0' + n);
        XkbBinding.create(seat, super, keysym, .{ .focus_workspace = n });
        XkbBinding.create(seat, super_shift, keysym, .{ .send_to_workspace = n });
    }

    PointerBinding.create(seat, super, event_codes.BTN_LEFT, .move);
    PointerBinding.create(seat, super, event_codes.BTN_RIGHT, .resize);
}

fn listener(_: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    switch (event) {
        .removed => seat.removed = true,
        .pointer_enter => |args| seat.hovered = if (args.window) |w| Window.fromObj(w) else null,
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
