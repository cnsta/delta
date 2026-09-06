const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const wp = wayland.client.wp;

const rules = @import("layouts/rules.zig");
const list = @import("util/list.zig");
const geom = @import("util/geom.zig");
const spawn = @import("spawn.zig").spawn;
const notify = @import("notify.zig");
const snapshot = @import("ipc/snapshot.zig");
const protocol = @import("ipc/protocol.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");
const Workspace = @import("Workspace.zig");
const Config = @import("Config.zig");
const Server = @import("ipc/Server.zig");
const Overlay = @import("overlay.zig");

const Delta = @This();

const log = std.log.scoped(.default);

pub var instance: Delta = undefined;

gpa: std.mem.Allocator,
io: std.Io,

obj: *river.WindowManagerV1,
xkb_bindings: *river.XkbBindingsV1,
layer_shell: ?*river.LayerShellV1,
compositor: ?*wl.Compositor = null,
viewporter: ?*wp.Viewporter = null,
single_pixel: ?*wp.SinglePixelBufferManagerV1 = null,
locked_applied: ?bool = null,

outputs: wl.list.Head(Output, .link),
windows: wl.list.Head(Window, .link),
seats: wl.list.Head(Seat, .link),
workspaces: wl.list.Head(Workspace, .link),

child_env: std.process.Environ.Map,
config: Config,
config_arena: std.heap.ArenaAllocator,
config_path: ?[]const u8 = null,
notify_socket: ?[]const u8 = null,

server: ?Server = null,
ipc_arena: std.heap.ArenaAllocator,
ipc_buf: std.ArrayList(u8) = .empty,
ipc_path: ?[]const u8 = null,
ipc_last: std.ArrayList(u8) = .empty,
ipc_dirty: bool = false,
registry: *wl.Registry,

default_output: ?*Output = null,

stop_deadline: ?i64 = null,
reload_deadline: ?i64 = null,

running: bool = true,
locked: bool = false,
notified: bool = false,
shutting_down: bool = false,

dirty: bool = false,

pub const stop_timeout_ms = 1000;
pub const reload_debounce_ms = 50;

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    child_env: std.process.Environ.Map,
    loaded: Config.Loaded,
    config_path: ?[]const u8,
    notify_socket: ?[]const u8,
    ipc_path: ?[]const u8,
    registry: *wl.Registry,
    wm_obj: *river.WindowManagerV1,
    xkb_bindings_obj: *river.XkbBindingsV1,
    layer_shell_obj: ?*river.LayerShellV1,
    compositor_obj: ?*wl.Compositor,
    viewporter_obj: ?*wp.Viewporter,
    single_pixel_obj: ?*wp.SinglePixelBufferManagerV1,
) void {
    instance = .{
        .gpa = gpa,
        .io = io,
        .child_env = child_env,

        .config = loaded.config,
        .config_arena = loaded.arena,
        .config_path = config_path,

        .notify_socket = notify_socket,
        .ipc_path = ipc_path,
        .ipc_arena = .init(gpa),

        .registry = registry,
        .obj = wm_obj,
        .xkb_bindings = xkb_bindings_obj,
        .layer_shell = layer_shell_obj,
        .compositor = compositor_obj,
        .viewporter = viewporter_obj,
        .single_pixel = single_pixel_obj,

        .outputs = undefined,
        .windows = undefined,
        .seats = undefined,
        .workspaces = undefined,
    };

    instance.outputs.init();
    instance.windows.init();
    instance.seats.init();
    instance.workspaces.init();

    instance.server = if (ipc_path) |path| Server.init(path) else null;
}

pub fn listener(
    _: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .unavailable => std.process.fatal("Another window manager is already running.", .{}),
        .finished => instance.running = false,
        .session_locked => instance.locked = true,
        .session_unlocked => instance.locked = false,
        .manage_start => instance.manageStart(),
        .render_start => instance.renderStart(),
        .window => |ev| Window.create(ev.id),
        .output => |ev| Output.create(ev.id),
        .seat => |ev| Seat.create(ev.id),
    }
}

fn manageStart(delta: *Delta) void {
    {
        var it = list.safeIterator(Window, .link, &delta.windows);
        while (it.next()) |window| window.maybeDestroy();
    }
    {
        var it = list.safeIterator(Output, .link, &delta.outputs);
        while (it.next()) |output| output.maybeDestroy();
    }
    {
        var it = list.safeIterator(Seat, .link, &delta.seats);
        while (it.next()) |seat| seat.maybeDestroy();
    }
    {
        var it = list.safeIterator(Seat, .link, &delta.seats);
        while (it.next()) |seat| seat.manage();
    }
    {
        var it = list.safeIterator(Window, .link, &delta.windows);
        while (it.next()) |window| window.manage();
    }
    {
        var it = list.safeIterator(Workspace, .link, &delta.workspaces);
        while (it.next()) |workspace| {
            const output = workspace.output orelse continue;

            workspace.arrange(rules.workArea(output));
        }
    }
    {
        var it = list.safeIterator(Workspace, .link, &delta.workspaces);
        while (it.next()) |workspace| workspace.settle();
    }
    {
        var it = list.safeIterator(Window, .link, &delta.windows);
        while (it.next()) |window| {
            window.syncSize();
            window.syncVisibility();
            window.syncFadeState();
        }
    }
    {
        var it = list.safeIterator(Seat, .link, &delta.seats);
        while (it.next()) |seat| seat.applyWarp();
    }
    {
        var it = list.safeIterator(Workspace, .link, &delta.workspaces);
        while (it.next()) |workspace| workspace.maybeDestroy();
    }

    delta.locked_applied = delta.locked;
    delta.syncLayerShellDefault();
    delta.publish();
    delta.obj.manageFinish();

    if (!delta.notified) {
        delta.notified = true;
        notify.ready(delta.notify_socket);
    }
}

fn syncLayerShellDefault(delta: *Delta) void {
    const seat = delta.seats.first() orelse return;
    const output = seat.output orelse return;
    if (delta.default_output == output) return;

    const shell = output.shell orelse return;
    shell.setDefault();
    delta.default_output = output;
}

fn renderStart(delta: *Delta) void {
    var it = delta.windows.iterator(.forward);
    while (it.next()) |window| {
        window.syncPosition();
        window.syncFade();
    }

    delta.obj.renderFinish();
}

pub fn reload(delta: *Delta) void {
    const path = delta.config_path orelse {
        log.warn("no config path, nothing to reload", .{});
        return;
    };

    var report: ?[]const u8 = null;
    defer if (report) |r| delta.gpa.free(r);

    const parsed = Config.load(delta.gpa, delta.io, path, &report) catch {
        log.err("out of memory reloading {s}", .{path});
        return;
    };

    if (parsed) |next| {
        var old = delta.config_arena;
        delta.config = next.config;
        delta.config_arena = next.arena;
        old.deinit();

        var it = list.safeIterator(Seat, .link, &delta.seats);
        while (it.next()) |seat| seat.reloadBindings();

        delta.dirty = true;

        log.info("reloaded {s}", .{path});
        return;
    }

    const message = report orelse return;
    log.err("{s}: {s}", .{ path, message });
    log.err("keeping the running configuration", .{});

    delta.reportConfigError(message);
}

pub fn scheduleReload(delta: *Delta) void {
    delta.reload_deadline = delta.millis() + reload_debounce_ms;
}

pub fn deinit(delta: *Delta) void {
    delta.shutting_down = true;

    while (delta.seats.first()) |seat| {
        seat.removed = true;
        seat.maybeDestroy();
    }
    while (delta.windows.first()) |window| {
        window.closed = true;
        window.maybeDestroy();
    }
    while (delta.outputs.first()) |output| {
        output.removed = true;
        output.maybeDestroy();
    }
    while (delta.workspaces.first()) |ws| {
        ws.output = null;
        ws.maybeDestroy();
    }

    delta.config_arena.deinit();
    if (delta.server) |*server| server.deinit();

    delta.ipc_arena.deinit();
    delta.ipc_buf.deinit(delta.gpa);
    delta.ipc_last.deinit(delta.gpa);
}

fn publish(delta: *Delta) void {
    if (!delta.ipc_dirty) return;
    delta.ipc_dirty = false;

    const server = if (delta.server) |*s| s else return;
    if (!server.hasStreamingClients()) return;

    _ = delta.ipc_arena.reset(.retain_capacity);
    const arena = delta.ipc_arena.allocator();

    const state = snapshot.build(arena) catch return;

    delta.ipc_buf.clearRetainingCapacity();

    inline for (.{
        protocol.Event{ .outputs_changed = state.outputs },
        protocol.Event{ .workspaces_changed = state.workspaces },
        protocol.Event{ .windows_changed = state.windows },
    }) |event| {
        const line = std.json.Stringify.valueAlloc(arena, event, .{}) catch return;
        delta.ipc_buf.appendSlice(delta.gpa, line) catch return;
        delta.ipc_buf.append(delta.gpa, '\n') catch return;
    }

    if (std.mem.eql(u8, delta.ipc_buf.items, delta.ipc_last.items)) return;

    server.publishRaw(delta.ipc_buf.items);

    delta.ipc_last.clearRetainingCapacity();
    delta.ipc_last.appendSlice(delta.gpa, delta.ipc_buf.items) catch {
        delta.ipc_last.clearRetainingCapacity();
    };
}

fn reportConfigError(delta: *Delta, message: []const u8) void {
    const command = delta.config.on_error orelse return;
    if (command.len == 0) return;

    const argv = delta.gpa.alloc([]const u8, command.len + 1) catch return;
    defer delta.gpa.free(argv);

    @memcpy(argv[0..command.len], command);
    argv[command.len] = message;

    spawn(argv);
}

pub fn requestStop(delta: *Delta) void {
    if (delta.stop_deadline != null) return;

    std.log.info("shutting down", .{});
    delta.obj.stop();
    delta.stop_deadline = delta.millis() + stop_timeout_ms;
}

pub fn stopping(delta: *const Delta) bool {
    return delta.stop_deadline != null;
}

fn frameInterval(delta: *Delta) i64 {
    var fastest: i32 = 0;

    var it = delta.outputs.iterator(.forward);
    while (it.next()) |output| {
        const mode = output.mode orelse continue;
        if (mode.refresh > fastest) fastest = mode.refresh;
    }

    if (fastest <= 0) return 16;

    return @max(1, @divTrunc(1_000_000, @as(i64, fastest)));
}

fn animating(delta: *Delta) bool {
    if (!delta.config.animation.enabled) return false;

    var win_it = delta.windows.iterator(.forward);
    while (win_it.next()) |window| {
        if (window.animating() or window.fading()) return true;
    }
    var ws_it = delta.workspaces.iterator(.forward);
    while (ws_it.next()) |ws| {
        if (ws.animating()) return true;
    }
    return false;
}

pub fn pollTimeout(delta: *Delta) i32 {
    var soonest: ?i64 = null;

    var it = delta.seats.iterator(.forward);
    while (it.next()) |seat| {
        const deadline = seat.repeatDeadline() orelse continue;
        if (soonest == null or deadline < soonest.?) soonest = deadline;
    }

    if (delta.stop_deadline) |deadline| {
        if (soonest == null or deadline < soonest.?) soonest = deadline;
    }

    if (delta.reload_deadline) |deadline| {
        if (soonest == null or deadline < soonest.?) soonest = deadline;
    }

    if (delta.animating()) {
        const next = delta.millis() + delta.frameInterval();
        if (soonest == null or next < soonest.?) soonest = next;
    }

    const at = soonest orelse return -1;

    return @intCast(@max(0, at - delta.millis()));
}

pub fn tick(delta: *Delta) void {
    const now = delta.millis();

    if (delta.stop_deadline) |deadline| {
        if (now >= deadline) {
            std.log.warn("no finished event within {d}ms, exiting anyway", .{stop_timeout_ms});
            delta.running = false;
            return;
        }
    }

    if (delta.reload_deadline) |deadline| {
        if (now >= deadline) {
            delta.reload_deadline = null;
            delta.reload();
        }
    }

    var it = list.safeIterator(Seat, .link, &delta.seats);
    while (it.next()) |seat| seat.tick(now);

    if (delta.animating()) {
        delta.dirty = true;
    }
}

pub fn millis(delta: *const Delta) i64 {
    return std.Io.Clock.now(.awake, delta.io).toMilliseconds();
}
