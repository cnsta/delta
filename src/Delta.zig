const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;

const rules = @import("layouts/rules.zig");
const list = @import("util/list.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");
const Workspace = @import("Workspace.zig");

const Delta = @This();

pub var instance: Delta = undefined;

gpa: std.mem.Allocator,
io: std.Io,

obj: *river.WindowManagerV1,
xkb_bindings: *river.XkbBindingsV1,
layer_shell: ?*river.LayerShellV1,

outputs: wl.list.Head(Output, .link),
windows: wl.list.Head(Window, .link),
seats: wl.list.Head(Seat, .link),
workspaces: wl.list.Head(Workspace, .link),

child_env: std.process.Environ.Map,

default_output: ?*Output = null,

stop_deadline: ?i64 = null,

running: bool = true,
locked: bool = false,

dirty: bool = false,

pub const stop_timeout_ms = 1000;

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    child_env: std.process.Environ.Map,
    wm_obj: *river.WindowManagerV1,
    xkb_bindings_obj: *river.XkbBindingsV1,
    layer_shell_obj: ?*river.LayerShellV1,
) void {
    instance = .{
        .gpa = gpa,
        .io = io,
        .child_env = child_env,

        .obj = wm_obj,
        .xkb_bindings = xkb_bindings_obj,
        .layer_shell = layer_shell_obj,

        .outputs = undefined,
        .windows = undefined,
        .seats = undefined,
        .workspaces = undefined,
    };

    instance.outputs.init();
    instance.windows.init();
    instance.seats.init();
    instance.workspaces.init();
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
        var it = list.safeIterator(Workspace, .link, &delta.workspaces);
        while (it.next()) |workspace| workspace.maybeDestroy();
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

            workspace.layout.arrange(rules.workArea(output));
        }
    }
    {
        var it = list.safeIterator(Seat, .link, &delta.seats);
        while (it.next()) |seat| seat.applyWarp();
    }

    delta.syncLayerShellDefault();

    // TODO(ipc): snapshot + diff + publish goes here, after every mutation and
    // before the transaction closes.

    delta.obj.manageFinish();
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
    var it = list.safeIterator(Window, .link, &delta.windows);
    while (it.next()) |window| window.center();

    delta.obj.renderFinish();
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

    var it = list.safeIterator(Seat, .link, &delta.seats);
    while (it.next()) |seat| seat.tick(now);
}

pub fn millis(delta: *const Delta) i64 {
    return std.Io.Clock.now(.awake, delta.io).toMilliseconds();
}
