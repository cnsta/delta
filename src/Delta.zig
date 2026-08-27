const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;

const list = @import("util/list.zig");

const rules = @import("layouts/rules.zig");

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

default_output: ?*Output = null,

child_env: std.process.Environ.Map,

running: bool = true,
locked: bool = false,
dirty: bool = false,

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    child_env: std.process.Environ.Map, // Add parameter here
    wm_obj: *river.WindowManagerV1,
    xkb_bindings_obj: *river.XkbBindingsV1,
    layer_shell_obj: ?*river.LayerShellV1,
) void {
    instance = .{
        .gpa = gpa,
        .io = io,
        .child_env = child_env, // Assign field here
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

pub fn pollTimeout(delta: *Delta) i32 {
    var soonest: ?i64 = null;

    var it = delta.seats.iterator(.forward);
    while (it.next()) |seat| {
        const at = seat.repeatDeadline() orelse continue;
        if (soonest == null or at < soonest.?) soonest = at;
    }

    const at = soonest orelse return -1;
    const now = std.Io.Clock.now(.awake, delta.io).toMilliseconds();
    const remaining = at - now;

    return @intCast(@max(0, remaining));
}

pub fn tick(delta: *Delta) void {
    const now = std.Io.Clock.now(.awake, delta.io).toMilliseconds();

    var it = list.safeIterator(Seat, .link, &delta.seats);
    while (it.next()) |seat| seat.tick(now);
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
    delta.obj.renderFinish();
}
