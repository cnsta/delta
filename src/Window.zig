const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const color = @import("util/color.zig");
const geom = @import("util/geom.zig");
const list = @import("util/list.zig");
const string = @import("util/string.zig");
const animation = @import("util/animation.zig");

const Eddy = @import("layouts/Eddy.zig");
const rules = @import("layouts/rules.zig");

const Config = @import("Config.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Workspace = @import("Workspace.zig");
const Overlay = @import("overlay.zig");

const log = std.log.scoped(.window);

const Window = @This();

obj: *river.WindowV1,
node: *river.NodeV1,
link: wl.list.Link,
workspace_link: wl.list.Link,

new: bool = true,
closed: bool = false,
raised: bool = false,

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
motion: animation.Lerp = .zero,
bounds: geom.Size = geom.Size.zero,
fade: ?Overlay = null,
fade_alpha: animation.Fade = .{ .settled = 0 },
pending_fade: bool = true,
proposed: geom.Size = geom.Size.zero,
tiled: ?rules.Edges = null,
decorated_focused: ?bool = null,
hidden: bool = false,
resizing: bool = false,
tiled_informed: bool = false,
floating: bool = false,
float_box: geom.Rect = geom.Rect.zero,

identifier_buf: [32]u8 = undefined,
identifier_len: u8 = 0,
app_id: ?[]const u8 = null,
title: ?[]const u8 = null,
pid: ?i32 = null,

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

pub fn identifier(window: *const Window) []const u8 {
    return window.identifier_buf[0..window.identifier_len];
}

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
    wm.ipc_dirty = true;
    window.pending_fade = true;
    window.fade_alpha = .{ .settled = 1 };
}

pub fn fromObj(obj: *river.WindowV1) *Window {
    return @ptrCast(@alignCast(obj.getUserData()));
}

pub fn maybeDestroy(window: *Window) void {
    if (!window.closed) return;
    wm.ipc_dirty = true;

    if (window.fade) |*fade| fade.destroy();
    window.fade = null;

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

    string.free(wm.gpa, &window.app_id);
    string.free(wm.gpa, &window.title);

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
    wm.ipc_dirty = true;

    if (window.workspace) |old| {
        old.layout.remove(window);
        window.workspace_link.remove();
    }

    const near = target.windows.last();

    window.workspace = target;
    target.windows.append(window);
    target.layout.insert(window, near, target.cursor());
}

pub fn placeAt(window: *Window, x: i32, y: i32) void {
    window.x = x;
    window.y = y;
    window.motion = .{ .settled = .{ .x = x, .y = y } };
}

pub fn setPosition(window: *Window, x: i32, y: i32) void {
    window.x = x;
    window.y = y;

    window.motion.retarget(
        .{ .x = x, .y = y },
        wm.millis(),
        wm.config.animation.duration_ms,
        wm.config.animation.curve,
    );
}

pub fn syncPosition(window: *Window) void {
    const ws = window.workspace orelse return;
    const origin = ws.origin() orelse return;

    const duration = wm.config.animation.duration_ms;
    const now = wm.millis();

    const local = window.motion.at(now, duration, wm.config.animation.curve);

    if (window.motion.done(now, duration)) window.motion.settle();

    const at: geom.Point = .{ .x = origin.x + local.x, .y = origin.y + local.y };
    if (window.placed) |last| {
        if (last.eql(at)) return;
    }

    window.node.setPosition(at.x, at.y);
    window.placed = at;
}

pub fn syncFade(window: *Window) void {
    const fade = if (window.fade) |*f| f else return;

    const duration = wm.config.animation.fade_ms;
    const now = wm.millis();

    const alpha = window.fade_alpha.at(now, duration, wm.config.animation.curve);

    fade.update(
        geom.Point.zero,
        window.slot.size(),
        Overlay.Color.rgba(wm.config.animation.fade_color, alpha),
    );
}

pub fn syncFadeState(window: *Window) void {
    if (window.fade) |*fade| {
        if (window.fade_alpha.done(wm.millis(), wm.config.animation.fade_ms)) {
            fade.destroy();
            window.fade = null;
        }
    }

    window.beginFade();
}

pub fn fading(window: *const Window) bool {
    if (!window.visible()) return false;
    if (wm.config.animation.fade_ms <= 0) return false;
    if (window.pending_fade) return true;
    if (window.fade == null) return false;
    return !window.fade_alpha.done(wm.millis(), wm.config.animation.fade_ms);
}

fn beginFade(window: *Window) void {
    if (!window.pending_fade) return;
    if (window.fade != null) return;
    if (!window.visible()) return;
    if (window.slot.width <= 0 or window.slot.height <= 0) return;

    const duration = wm.config.animation.fade_ms;
    if (duration <= 0) {
        window.pending_fade = false;
        return;
    }

    window.fade = Overlay.create(window) orelse return;
    window.pending_fade = false;

    window.fade_alpha = .{ .moving = .{
        .from = 1,
        .to = 0,
        .start = wm.millis(),
    } };
}

pub fn animating(window: *const Window) bool {
    if (!window.visible()) return false;

    return !window.motion.done(wm.millis(), wm.config.animation.duration_ms);
}

fn syncBounds(window: *Window) void {
    const wanted: geom.Size = if (window.fullscreen != null or window.slot.width == 0)
        geom.Size.zero
    else
        window.slot.size();

    if (wanted.eql(window.bounds)) return;

    window.obj.setDimensionBounds(wanted.width, wanted.height);
    window.bounds = wanted;
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
        window.float_box = window.initialFloatBox(area);
    }

    window.apply(rules.placeFloating(window.float_box, area, window.limits));
}

fn initialFloatBox(window: *const Window, area: geom.Rect) geom.Rect {
    const middle = middle: {
        const parent = window.parent orelse break :middle area.center();

        if (parent.slot.width == 0) break :middle area.center();
        break :middle parent.slot.center();
    };

    return .{
        .x = middle.x - @divTrunc(window.width, 2),
        .y = middle.y - @divTrunc(window.height, 2),
        .width = window.width,
        .height = window.height,
    };
}

fn apply(window: *Window, p: rules.Placement) void {
    if (window.fullscreen != null) return;

    window.syncTiled();

    if (!p.content.size().eql(window.slot.size())) {
        window.overshoot = geom.Size.zero;
        window.propose(p.content.size());
        window.obj.setContentClipBox(0, 0, p.content.width, p.content.height);
    }

    const size_changed = !p.content.size().eql(window.slot.size());
    const origin_moved = p.content.x != window.slot.x or p.content.y != window.slot.y;

    window.slot = p.content;

    if (size_changed or origin_moved) {
        log.info("apply {s}: {d}x{d}@{d},{d} -> {d}x{d}@{d},{d} size={} origin={}", .{
            window.identifier(),
            window.slot.width,
            window.slot.height,
            window.slot.x,
            window.slot.y,
            p.content.width,
            p.content.height,
            p.content.x,
            p.content.y,
            size_changed,
            origin_moved,
        });
    }

    if (window.placed == null) {
        window.placeInSlot(.immediate);
    } else {
        window.placeInSlot(.animated);
    }
}

const Placement = enum { immediate, animated };

fn placeInSlot(window: *Window, how: Placement) void {
    switch (how) {
        .immediate => window.placeAt(window.slot.x, window.slot.y),
        .animated => window.setPosition(window.slot.x, window.slot.y),
    }
}

fn propose(window: *Window, size: geom.Size) void {
    window.proposed = size;
    window.obj.proposeDimensions(size.width, size.height);
}

fn syncTiled(window: *Window) void {
    if (window.tiled_informed) return;

    window.obj.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    window.tiled_informed = true;
}

fn currentOutput(window: *Window) ?*Output {
    const ws = window.workspace orelse return null;
    return ws.output;
}

pub fn toggleFullscreen(window: *Window) void {
    window.fullscreen = if (window.fullscreen != null) null else window.currentOutput();
    wm.ipc_dirty = true;
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

pub fn raiseFloating(ws: *Workspace) void {
    var it = ws.windows.iterator(.forward);
    while (it.next()) |window| {
        if (!window.floating or !window.visible()) continue;
        if (window.raised) continue;

        window.node.placeTop();

        var others = ws.windows.iterator(.forward);
        while (others.next()) |other| other.raised = false;
        window.raised = true;
    }
}

pub fn toggleFloating(window: *Window) void {
    window.setFloating(!window.floating);
}

pub fn setFloating(window: *Window, on: bool) void {
    if (window.floating == on) return;
    window.floating = on;
    wm.ipc_dirty = true;

    const ws = window.workspace orelse return;

    if (on) {
        ws.layout.remove(window);

        if (window.float_box.width == 0 and window.slot.width > 0) {
            window.float_box = window.slot;
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
    const want_hidden = !window.visible() or window.slot.width == 0;
    if (want_hidden == window.hidden) return;

    if (want_hidden) window.obj.hide() else window.obj.show();
    window.hidden = want_hidden;
}

pub fn sized(window: *const Window) bool {
    return window.width > 0 and window.height > 0;
}

pub fn syncSize(window: *Window) void {
    if (window.slot.width == 0 or !window.sized()) return;

    const short_w = @max(0, window.slot.width - window.width);
    const short_h = @max(0, window.slot.height - window.height);
    if (short_w == 0 and short_h == 0) return;
    if (short_w > max_overshoot or short_h > max_overshoot) {
        if (!window.proposed.eql(window.slot.size())) window.propose(window.slot.size());
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

pub fn focused(window: *const Window) bool {
    return window.focus_count > 0;
}

pub fn syncDecoration(window: *Window) void {
    const is_focused = window.focused();
    if (window.decorated_focused) |applied| {
        if (applied == is_focused) return;
    }

    const c = if (is_focused)
        color.hex(wm.config.border.focused)
    else
        color.hex(wm.config.border.inactive);

    window.obj.setBorders(
        .{ .top = true, .bottom = true, .left = true, .right = true },
        wm.config.border.width,
        c.r,
        c.g,
        c.b,
        c.a,
    );
    window.decorated_focused = is_focused;
}

fn fixedSize(window: *const Window) bool {
    const min = window.limits.min;
    const max = window.limits.max;

    if (min.width > 0 and min.width == max.width) return true;
    if (min.height > 0 and min.height == max.height) return true;
    return false;
}

pub fn isDialog(window: *const Window) bool {
    return window.parent != null or window.fixedSize();
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

        const applied = wm.config.resolve(.{
            .app_id = window.app_id,
            .title = window.title,
            .dialog = window.parent != null,
        });

        window.setWorkspace(if (applied.workspace) |id|
            Workspace.get(id)
        else
            window.initialWorkspace());

        if (applied.floating orelse (window.parent != null)) window.setFloating(true);
        if (applied.fullscreen orelse false) window.toggleFullscreen();

        window.syncNewFocus(applied);

        log.debug("mapped {s} app_id={?s} title={?s} dialog={} min={d}x{d} max={d}x{d}", .{
            window.identifier(),
            window.app_id,
            window.title,
            window.parent != null,
            window.limits.min.width,
            window.limits.min.height,
            window.limits.max.width,
            window.limits.max.height,
        });
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
        .exit => {
            window.fullscreen = null;
            wm.ipc_dirty = true;
        },
    }
    window.fullscreen_request = .none;
    window.syncFullscreen();
    window.syncResizing();
    window.syncDecoration();
    window.syncVisibility();

    if (window.fullscreen != null) return;

    window.syncBounds();
}

fn syncNewFocus(window: *Window, applied: Config.Resolved) void {
    const seat = wm.seats.first() orelse return;

    if (!(applied.focused orelse wm.config.input.focus_new_windows)) {
        const previous = seat.focused orelse return;
        seat.dropFocus();
        _ = seat.focus(previous);
        return;
    }

    if (!window.visible()) return;

    const warp = applied.warp orelse true;
    if (seat.focus(window) and warp and Seat.warpOnSpawn()) seat.warpTo(window);
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

        .identifier => |args| window.setIdentifier(args.identifier),

        .parent => |args| {
            window.parent = if (args.parent) |p| fromObj(p) else null;
            log.debug("parent {s} -> {}", .{ window.identifier(), window.parent != null });
        },

        .app_id => |args| {
            if (string.replace(wm.gpa, &window.app_id, args.app_id) catch
                fatal("Out of memory.", .{}))
            {
                wm.ipc_dirty = true;
                log.debug("app_id {s} = {?s}", .{ window.identifier(), window.app_id });
            }
        },

        .title => |args| {
            if (string.replace(wm.gpa, &window.title, args.title) catch
                fatal("Out of memory.", .{}))
            {
                wm.ipc_dirty = true;
                log.debug("title {s} = {?s}", .{ window.identifier(), window.title });
            }
        },

        .unreliable_pid => |args| window.pid = args.unreliable_pid,

        else => {},
    }
}

fn setIdentifier(window: *Window, id: [*:0]const u8) void {
    const value = std.mem.sliceTo(id, 0);
    const len = @min(value.len, window.identifier_buf.len);

    @memcpy(window.identifier_buf[0..len], value[0..len]);
    window.identifier_len = @intCast(len);

    if (len != value.len) {
        log.warn("identifier truncated from {d} bytes: {s}", .{ value.len, window.identifier() });
    }
}
