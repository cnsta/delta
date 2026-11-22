const std = @import("std");
const wayland = @import("wayland");
const xkb = @import("xkbcommon");
const event_codes = @import("event-codes");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const geom = @import("util/geom.zig");
const glob = @import("util/glob.zig");
const seatpick = @import("util/seatpick.zig");
const spawn = @import("spawn.zig").spawn;

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
focus_resync: bool = false,
refocus_after_lock: bool = false,
warp_to: ?*Window = null,
last_input: Input = .pointer,

xkb_bindings: wl.list.Head(XkbBinding, .link),
pointer_bindings: wl.list.Head(PointerBinding, .link),
pending: Action.Queue = .{},

repeat_binding: ?*XkbBinding = null,

repeat_at: i64 = 0,

op: Op = .none,
op_dx: i32 = 0,
op_dy: i32 = 0,
op_started: i64 = 0,
op_release: bool = false,

shell: ?*river.LayerShellSeatV1 = null,

layer_focus: LayerFocus = .none,

pointer: geom.Point = geom.Point.zero,
pointer_known: bool = false,

output: ?*Output = null,

last_workspace: ?Workspace.Id = null,

ipc_args: std.heap.ArenaAllocator,

pub const LayerFocus = enum { none, non_exclusive, exclusive };

// -- lifecycle ---------------------------------------------------------

pub fn create(river_seat: *river.SeatV1) void {
    const seat = wm.gpa.create(Seat) catch fatal("Out of memory.", .{});
    seat.* = .{
        .obj = river_seat,
        .link = undefined,
        .xkb_bindings = undefined,
        .pointer_bindings = undefined,
        .ipc_args = .init(wm.gpa),
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
    seat.applyCursorTheme();
}

pub fn applyCursorTheme(seat: *Seat) void {
    const cursor = wm.config.input.cursor;
    const theme = cursor.theme orelse return;
    seat.obj.setXcursorTheme(theme.ptr, cursor.size);
}

pub fn fromObj(obj: *river.SeatV1) *Seat {
    return @ptrCast(@alignCast(obj.getUserData()));
}

pub fn maybeDestroy(seat: *Seat) void {
    if (!seat.removed) return;

    seat.repeat_binding = null;
    seat.pending.clear();

    if (seat.focused) |w| w.focus_count -= 1;
    seat.focused = null;
    wm.ipc_dirty = true;

    while (seat.xkb_bindings.first()) |binding| binding.destroy();
    while (seat.pointer_bindings.first()) |binding| binding.destroy();

    if (seat.shell) |shell| shell.destroy();

    if (wm.active_seat == seat) wm.active_seat = null;

    seat.ipc_args.deinit();
    seat.obj.destroy();
    seat.link.remove();
    wm.gpa.destroy(seat);
}

pub fn markActive(seat: *Seat) void {
    if (seat.removed) return;
    if (wm.active_seat == seat) return;

    wm.active_seat = seat;
    wm.ipc_dirty = true;
}

pub fn forgetWindow(seat: *Seat, window: *Window) void {
    if (seat.warp_to == window) seat.warp_to = null;
    if (seat.focused == window) {
        window.focus_count -= 1;
        seat.focused = null;
        seat.obj.clearFocus();
    }
    if (seat.hovered == window) seat.hovered = null;
    if (seat.interacted == window) seat.interacted = null;

    switch (seat.op) {
        .none => {},
        .move => |*m| {
            if (m.drop) |drop| {
                if (drop.target == window) clearDrop(m);
            }
            if (m.window == window) {
                clearDrop(m);
                seat.obj.opEnd();
                seat.op = .none;
            }
        },
        .resize => |args| if (args.window == window) {
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
    return o.activeWorkspace();
}

fn focusState(seat: *const Seat) seatpick.Focus {
    const window = seat.focused orelse return .none;
    const ws = window.workspace;
    const shown = if (ws) |w| w.output != null and !window.unfocusable() else false;
    return seatpick.classifyFocus(true, ws != null, shown);
}

fn revalidateFocus(seat: *Seat) void {
    if (seat.focusState() == .stale) seat.dropFocus();
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
    seat.syncBindings(!wm.locked);
    seat.updateOutput();

    if (wm.locked) {
        seat.endOp();
        seat.interacted = null;
        seat.focus_resync = false;
        seat.pending.clear();
        seat.repeat_binding = null;
        seat.op_release = false;
        seat.refocus_after_lock = true;
        return;
    }

    seat.revalidateFocus();

    if (seat.refocus_after_lock) {
        seat.refocus_after_lock = false;
        const was = seat.focused;
        seat.dropFocus();
        _ = seat.focusNoRaise(was);
    }

    switch (seat.layer_focus) {
        .exclusive => seat.dropFocus(),
        .non_exclusive => if (seat.interacted) |w| {
            seat.focusInteracted(w);
        } else seat.dropFocus(),
        .none => seat.focusInteracted(seat.interacted),
    }
    seat.interacted = null;
    seat.focus_resync = false;

    while (seat.pending.pop()) |action| action.execute(seat);
    _ = seat.ipc_args.reset(.retain_capacity);

    const op_timeout_ms = 30_000;

    if (seat.op_release) {
        seat.finishDrop();
        seat.endOp();
    } else if (seat.op != .none and wm.millis() - seat.op_started > op_timeout_ms) {
        log.warn("pointer op ran for {d}ms without a release, ending it", .{
            wm.millis() - seat.op_started,
        });
        seat.endOp();
    } else switch (seat.op) {
        .none => {},
        .move => |*m| {
            if (!m.dragging) {
                const t = wm.config.input.drag_threshold;
                if (seat.op_dx * seat.op_dx + seat.op_dy * seat.op_dy >= t * t) m.dragging = true;
            }

            if (!m.dragging) {} else if (m.window.float) {
                m.window.moveFloat(
                    seat.op_dx - m.applied_dx,
                    seat.op_dy - m.applied_dy,
                );
                m.applied_dx = seat.op_dx;
                m.applied_dy = seat.op_dy;
            } else {
                seat.dragTiled(m);
            }
        },

        .resize => |*args| {
            const dx = seat.op_dx - args.applied_dx;
            const dy = seat.op_dy - args.applied_dy;

            if (args.window.float) {
                if (args.start.width > 0) args.window.float_box = rules.resizeBox(
                    args.start,
                    seat.op_dx,
                    seat.op_dy,
                    args.edges,
                    args.window.limits,
                );
            } else {
                Eddy.resizeEdge(args.window, dx, dy, args.edges);
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

    if (seat.focused == window and window.visible() and
        (window.slot.width <= 0 or window.slot.height <= 0)) return;

    seat.warp_to = null;

    if (seat.focused != window) return;
    if (seat.op != .none) return;
    if (!window.visible()) return;

    const ws = window.workspace orelse return;
    const output = ws.output orelse return;

    if (!warpOnFocus()) {
        seat.output = output;
        return;
    }

    const x = output.x + window.slot.x + @divTrunc(window.slot.width, 2);
    const y = output.y + window.slot.y + @divTrunc(window.slot.height, 2);
    seat.obj.pointerWarp(x, y);
    seat.pointer = .{ .x = x, .y = y };
    seat.pointer_known = true;
    seat.output = ws.output;
}

fn endOp(seat: *Seat) void {
    if (seat.op == .none) return;
    switch (seat.op) {
        .move => |*m| clearDrop(m),
        else => {},
    }

    seat.obj.opEnd();
    seat.op = .none;
}

pub const Op = union(enum) {
    none,
    move: Move,
    resize: struct {
        window: *Window,
        edges: rules.Edges,
        start: geom.Rect,
        applied_dx: i32 = 0,
        applied_dy: i32 = 0,
    },

    pub const Move = struct {
        window: *Window,
        applied_dx: i32 = 0,
        applied_dy: i32 = 0,

        dragging: bool = false,

        drop: ?Drop = null,
    };

    /// The tile under the pointer and where in it, applied on release.
    pub const Drop = struct {
        target: *Window,
        tile: geom.Rect,
        point: geom.Point,
    };
};

fn dragTiled(seat: *Seat, m: *Op.Move) void {
    if (!seat.pointer_known) return;

    const ws = m.window.workspace orelse return clearDrop(m);
    const origin = ws.origin() orelse return clearDrop(m);

    const point: geom.Point = .{
        .x = seat.pointer.x - origin.x,
        .y = seat.pointer.y - origin.y,
    };
    if (!ws.layout.area.contains(point)) return clearDrop(m);

    const hit = ws.layout.tileAt(point) orelse return clearDrop(m);
    if (hit.window == m.window) return clearDrop(m);

    if (m.drop) |old| {
        if (old.target != hit.window) old.target.hideDropPreview();
    }
    m.drop = .{ .target = hit.window, .tile = hit.rect, .point = point };

    const zone = Eddy.dropZone(hit.rect, point);
    hit.window.showDropPreview(Eddy.dropPreview(hit.window.slot.size(), zone));
}

fn clearDrop(m: *Op.Move) void {
    const drop = m.drop orelse return;
    drop.target.hideDropPreview();
    m.drop = null;
}

fn finishDrop(seat: *Seat) void {
    const m = switch (seat.op) {
        .move => |*m| m,
        else => return,
    };
    const drop = m.drop orelse return;
    clearDrop(m);
    if (!m.dragging or m.window.float) return;

    const ws = m.window.workspace orelse return;
    ws.layout.dropOnto(m.window, drop.target, drop.tile, drop.point);
    wm.dirty = true;
    wm.ipc_dirty = true;
    seat.warpTo(m.window);
}

pub fn tick(seat: *Seat, now: i64) void {
    const binding = seat.repeat_binding orelse return;
    if (now < seat.repeat_at) return;

    if (wm.locked) {
        seat.repeat_binding = null;
        return;
    }

    _ = seat.pending.push(binding.action);

    const rate = wm.config.input.repeat_rate;
    if (rate == 0) {
        seat.repeat_binding = null;
        return;
    }
    seat.repeat_at = now + @max(1, 1000 / rate);
    wm.dirty = true;
}

// -- focus -------------------------------------------------------------

pub fn focus(seat: *Seat, window: ?*Window) bool {
    return seat.focusAndMaybeRaise(window, true);
}

pub fn focusNoRaise(seat: *Seat, window: ?*Window) bool {
    return seat.focusAndMaybeRaise(window, false);
}

fn focusAndMaybeRaise(seat: *Seat, window: ?*Window, raise_it: bool) bool {
    const target = window orelse blk: {
        if (!seatpick.mayFallBack(seat.focusState())) return false;

        const ws = seat.workspace() orelse break :blk null;
        break :blk ws.lastFocusable();
    };

    if (target) |w| {
        if (w.workspace) |ws| {
            if (ws.output == null) return false;
        }
        if (w.unfocusable()) return false;
    }

    if (seat.focused == target) return false;

    if (seat.focused) |old| old.focus_count -= 1;

    if (target) |w| {
        seat.obj.focusWindow(w.obj);
        if (raise_it) raise(w);
        w.focus_count += 1;
        wm.focus_serial += 1;
        w.focus_serial = wm.focus_serial;
    } else {
        seat.obj.clearFocus();
    }

    seat.focused = target;
    wm.ipc_dirty = true;
    return true;
}

/// `ws.windows` order is raise order: the last window is the topmost.
fn raise(w: *Window) void {
    w.link.remove();
    wm.windows.append(w);

    w.node.placeTop();
    if (w.workspace) |ws| {
        w.workspace_link.remove();
        ws.windows.append(w);
        ws.raiseFloat();
    }
}

pub fn dropFocus(seat: *Seat) void {
    const old = seat.focused orelse return;
    old.focus_count -= 1;
    seat.focused = null;
    seat.obj.clearFocus();
    wm.ipc_dirty = true;
}

fn focusInteracted(seat: *Seat, window: ?*Window) void {
    if (seat.focus_resync) {
        seat.dropFocus();
        _ = seat.focus(window);
        return;
    }
    _ = seat.focusNoRaise(window);
}

pub const Input = enum { keyboard, pointer };

pub fn warpTo(seat: *Seat, window: ?*Window) void {
    if (window) |w| seat.warp_to = w;
}

pub fn focusNext(seat: *Seat) void {
    const ws = seat.workspace() orelse return;
    var it = ws.windows.iterator(.forward);
    const target = while (it.next()) |w| {
        if (!w.unfocusable()) break w;
    } else return;
    if (seat.focus(target)) seat.warpTo(seat.focused);
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

pub fn moveDirection(seat: *Seat, dir: geom.Direction) void {
    const window = seat.focused orelse return;
    if (window.float) return;
    const ws = window.workspace orelse return;

    const target = ws.windowInDirection(window, dir) orelse return;
    if (target.float) return;

    ws.layout.swap(window, target);
    wm.ipc_dirty = true;
    wm.dirty = true;

    seat.warpTo(window);
}

pub fn toggleSplit(seat: *Seat) void {
    const window = seat.focused orelse return;

    if (window.float) return;
    if (window.fullscreen != null) return;

    const ws = window.workspace orelse return;
    if (!Eddy.toggleSplit(window)) return;

    _ = ws;
    wm.dirty = true;
}

fn baseWorkspace(seat: *Seat) ?*Workspace {
    const ws = seat.workspace() orelse return null;
    if (ws != &wm.scratchpad) return ws;
    const output = seat.output orelse return null;
    return output.workspace;
}

pub fn focusWorkspaceAction(seat: *Seat, id: Workspace.Id) void {
    if (wm.config.input.workspace_back_and_forth and !wm.scratchpad_open) {
        if (seat.baseWorkspace()) |ws| {
            if (ws.id == id) {
                if (seat.last_workspace) |last| return seat.focusWorkspace(last);
            }
        }
    }
    seat.focusWorkspace(id);
}

pub fn focusWorkspacePrevious(seat: *Seat) void {
    const last = seat.last_workspace orelse return;
    seat.focusWorkspace(last);
}

pub const Step = enum { next, prev, next_occupied, prev_occupied };

pub fn cycleWorkspace(seat: *Seat, step: Step) void {
    const base = (seat.baseWorkspace() orelse return).id;
    const target: ?Workspace.Id = switch (step) {
        .next => if (base < std.math.maxInt(Workspace.Id)) base + 1 else null,
        .prev => if (base > 1) base - 1 else null,
        .next_occupied => blk: {
            var it = wm.workspaces.iterator(.forward);
            while (it.next()) |ws| {
                if (ws.id > base and !ws.isEmpty()) break :blk ws.id;
            }
            break :blk null;
        },
        .prev_occupied => blk: {
            var it = wm.workspaces.iterator(.reverse);
            while (it.next()) |ws| {
                if (ws.id < base and !ws.isEmpty()) break :blk ws.id;
            }
            break :blk null;
        },
    };
    if (target) |id| seat.focusWorkspace(id);
}

pub fn focusLast(seat: *Seat) void {
    var best: ?*Window = null;
    var it = wm.windows.iterator(.forward);
    while (it.next()) |w| {
        if (w == seat.focused or w.focus_serial == 0 or w.workspace == null) continue;
        if (w.stashed) continue;
        if (best == null or w.focus_serial > best.?.focus_serial) best = w;
    }
    const target = best orelse return;
    const ws = target.workspace.?;

    if (ws == &wm.scratchpad) {
        wm.openScratchpad(seat);
    } else if (ws.output == null) {
        seat.focusWorkspace(ws.id);
    } else if (wm.scratchpad_open and wm.scratchpad.output == ws.output) {
        wm.closeScratchpad();
    }

    seat.dropFocus();
    if (seat.focus(target)) seat.warpTo(target);
}

pub fn focusWorkspace(seat: *Seat, id: Workspace.Id) void {
    if (id == 0) return;
    const before = seat.baseWorkspace();
    wm.closeScratchpad();
    const target = Workspace.getOrCreate(id);

    if (seat.workspace() == target) return;
    if (before) |ws| {
        if (ws != target) seat.last_workspace = ws.id;
    }

    if (seat.output) |o| {
        o.setWorkspace(target);
    } else if (target.output == null) {
        if (wm.outputs.first()) |o| o.setWorkspace(target);
    }

    seat.dropFocus();
    _ = seat.focus(target.windows.last());
}

pub fn sendToWorkspace(seat: *Seat, id: Workspace.Id) void {
    if (id == 0) return;
    const window = seat.focused orelse return;
    const target = Workspace.getOrCreate(id);
    if (window.workspace == target) return;

    window.pending_move = null;
    window.scratch_home = null;
    window.setWorkspace(target);
    window.manual.workspace = true;

    if (wm.config.input.follow_sent_windows) {
        seat.dropFocus();
        seat.focusWorkspace(id);
        return;
    }

    seat.dropFocus();
    if (seat.focus(null)) seat.warpTo(seat.focused);
}

/// Sends the focused window to the scratchpad, or a scratchpad window back
/// to the workspace it came from (else the one under the scratchpad).
pub fn toggleScratchpadWindow(seat: *Seat) void {
    const window = seat.focused orelse return;
    const ws = window.workspace orelse return;

    if (ws == &wm.scratchpad) {
        const home = window.scratch_home orelse
            if (wm.scratchpad.output orelse seat.output) |o| o.workspace.id else 1;
        window.scratch_home = null;
        window.moveTo(.{ .workspace = home });
    } else {
        window.scratch_home = ws.id;
        window.moveTo(.scratchpad);
    }
    window.manual.workspace = true;

    seat.dropFocus();
    if (seat.focus(null)) seat.warpTo(seat.focused);
}

// -- window actions ----------------------------------------------------

pub fn toggleApp(seat: *Seat, args: []const []const u8) void {
    const window = findApp(args[0]) orelse {
        if (args.len > 1 and !wm.hide_all) spawn(args[1..]);
        return;
    };
    const here = if (seat.output) |o| o.activeWorkspace() else Workspace.forNewWindow();

    if (!window.stashed and window.workspace == here and window.visible() and !window.unfocusable()) {
        if (seat.focused != window) {
            if (seat.focus(window)) seat.warpTo(window);
            return;
        }
        window.stashed = true;
        wm.dirty = true;
        wm.ipc_dirty = true;
        seat.dropFocus();
        if (seat.focus(null)) seat.warpTo(seat.focused);
        return;
    }

    window.stashed = false;
    window.pending_move = null;
    window.scratch_home = null;
    if (window.fullscreen == null) {
        window.setFloat(true);
        window.manual.float = true;
    }
    if (window.workspace != here) {
        window.setWorkspace(here);
        window.manual.workspace = true;
        if (window.float) here.raiseFloat();
    }
    window.desktop_enter = true;
    wm.dirty = true;
    wm.ipc_dirty = true;

    seat.dropFocus();
    if (seat.focus(window)) seat.warpTo(window);
}

fn findApp(pattern: []const u8) ?*Window {
    var it = wm.windows.iterator(.forward);
    while (it.next()) |w| {
        const app_id = w.app_id orelse continue;
        if (w.workspace != null and glob.match(pattern, app_id)) return w;
    }
    return null;
}

pub fn toggleSticky(seat: *Seat) void {
    const window = seat.focused orelse return;
    if (window.fullscreen != null) return;
    window.setSticky(!window.sticky);
    window.manual.float = true;
    wm.dirty = true;
}

pub fn closeFocused(seat: *Seat) void {
    const window = seat.focused orelse return;
    window.obj.close();
}

pub fn toggleFullscreen(seat: *Seat) void {
    const window = seat.focused orelse return;
    window.toggleFullscreen();
    window.manual.fullscreen = true;
}

pub fn toggleFloat(seat: *Seat) void {
    const window = seat.focused orelse return;

    if (window.fullscreen != null) return;

    window.toggleFloat();
    window.manual.float = true;
}

pub fn resizeStep(seat: *Seat, how: Action.Resize) void {
    const window = seat.focused orelse return;

    if (window.fullscreen != null) return;
    const step = rules.resizeStep();

    if (window.float) {
        switch (how) {
            .grow_width => window.resizeFloat(step, 0),
            .shrink_width => window.resizeFloat(-step, 0),
            .grow_height => window.resizeFloat(0, step),
            .shrink_height => window.resizeFloat(0, -step),
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
    seat.pointerResize(window, null);
}

pub fn pointerMove(seat: *Seat, window: *Window) void {
    if (seat.op != .none) return;

    _ = seat.focus(window);
    seat.obj.opStartPointer();
    seat.op = .{ .move = .{ .window = window } };
    seat.op_dx = 0;
    seat.op_dy = 0;
    seat.op_started = wm.millis();
}

pub fn pointerResize(seat: *Seat, window: *Window, edges: ?rules.Edges) void {
    if (seat.op != .none) return;

    const chosen = edges orelse seat.grabbedCorner(window);

    _ = seat.focus(window);
    seat.obj.opStartPointer();
    seat.op = .{ .resize = .{
        .window = window,
        .edges = chosen,
        .start = window.float_box,
    } };
    if (window.float) window.resize_anchor = chosen;
    seat.op_dx = 0;
    seat.op_dy = 0;
    seat.op_started = wm.millis();
}

fn grabbedCorner(seat: *const Seat, window: *const Window) rules.Edges {
    const fallback: rules.Edges = .{ .right = true, .bottom = true };
    if (!seat.pointer_known) return fallback;

    const ws = window.workspace orelse return fallback;
    const output = ws.output orelse return fallback;
    if (window.slot.width <= 0 or window.slot.height <= 0) return fallback;

    const global: geom.Rect = .{
        .x = output.x + window.slot.x,
        .y = output.y + window.slot.y,
        .width = window.slot.width,
        .height = window.slot.height,
    };
    return rules.resizeEdges(global, seat.pointer);
}

// -- key repeat --------------------------------------------------------

pub fn beginRepeat(seat: *Seat, binding: *XkbBinding) void {
    if (!binding.action.repeats() or wm.config.input.repeat_rate == 0) return;

    seat.repeat_binding = binding;
    seat.repeat_at = wm.millis() + wm.config.input.repeat_delay;
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
    seat.pending.clear();

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
    XkbBinding.create(seat, super_shift, .f, .toggle_float);
    XkbBinding.create(seat, super, .n, .focus_next);

    const arrows = [4]u32{ 0xff51, 0xff53, 0xff52, 0xff54 };
    const letters = [4]xkb.Keysym{ .h, .l, .k, .j };
    const dirs = [4]geom.Direction{ .left, .right, .up, .down };

    inline for (arrows, letters, dirs) |arrow, letter, dir| {
        const key: xkb.Keysym = @fromBackingInt(@intCast(arrow));

        XkbBinding.create(seat, super, key, .{ .focus_direction = dir });
        XkbBinding.create(seat, super, letter, .{ .focus_direction = dir });

        XkbBinding.create(seat, super_shift, key, .{ .move_direction = dir });
        XkbBinding.create(seat, super_shift, letter, .{ .move_direction = dir });
    }

    XkbBinding.create(seat, super, .v, .toggle_split);
    XkbBinding.create(seat, super, .Tab, .scratchpad);
    XkbBinding.create(seat, super_shift, .s, .send_to_scratchpad);

    const question: xkb.Keysym = @fromBackingInt(@intCast(0x03f));
    const minus: xkb.Keysym = @fromBackingInt(@intCast(0x02d));
    const plus: xkb.Keysym = @fromBackingInt(@intCast(0x02b));
    const underscore: xkb.Keysym = @fromBackingInt(@intCast(0x05f));
    const kp_add: xkb.Keysym = @fromBackingInt(@intCast(0xffab));
    const kp_subtract: xkb.Keysym = @fromBackingInt(@intCast(0xffad));

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
        const keysym: xkb.Keysym = @fromBackingInt(@intCast('0' + n));
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
        .window_interaction => |args| {
            seat.markActive();
            seat.last_input = .pointer;
            seat.interacted = if (args.window) |w| Window.fromObj(w) else null;
            seat.focus_resync = true;
        },
        .op_delta => |args| {
            seat.op_dx = args.dx;
            seat.op_dy = args.dy;
        },
        .op_release => seat.op_release = true,
        .pointer_position => |args| {
            seat.markActive();
            seat.last_input = .pointer;
            seat.pointer = .{ .x = args.x, .y = args.y };
            seat.pointer_known = true;
        },
        .wl_seat => {},
        .shell_surface_interaction => {},
        .op_delta_touch, .op_release_touch, .op_cancel_touch => {},
    }
}
