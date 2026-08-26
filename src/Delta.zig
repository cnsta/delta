const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;

const list = @import("util/list.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");
// const Workspace = @import("Workspace.zig");

const Delta = @This();

pub var instance: Delta = undefined;

gpa: std.mem.Allocator,
io: std.Io,

obj: *river.WindowManagerV1,
xkb_bindings: *river.XkbBindingsV1,

outputs: wl.list.Head(Output, .link),
windows: wl.list.Head(Window, .link),
seats: wl.list.Head(Seat, .link),
// workspaces: wl.list.Head(Workspace, .link),

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    wm_obj: *river.WindowManagerV1,
    xkb_bindings_obj: *river.XkbBindingsV1,
) void {
    instance = .{
        .gpa = gpa,
        .io = io,

        .obj = wm_obj,
        .xkb_bindings = xkb_bindings_obj,

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
        .finished => std.process.exit(0),
        .manage_start => instance.manageStart(),
        .render_start => instance.renderStart(),
        .window => |ev| Window.create(ev.id),
        .output => |ev| Output.create(ev.id),
        .seat => |ev| Seat.create(ev.id),
        else => {},
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
    // {
    //     var it = list.safeIterator(Workspace, .link, &delta.workspaces);
    //     while (it.next()) |workspace| workspace.maybeDestroy();
    // }

    {
        var it = list.safeIterator(Seat, .link, &delta.seats);
        while (it.next()) |seat| seat.manage();
    }
    {
        var it = list.safeIterator(Window, .link, &delta.windows);
        while (it.next()) |window| window.manage();
    }

    // TODO(ipc): snapshot + diff + publish goes here, after every mutation and
    // before the transaction closes.

    delta.obj.manageFinish();
}

fn renderStart(delta: *Delta) void {
    var it = list.safeIterator(Seat, .link, &delta.seats);
    while (it.next()) |seat| seat.render();

    delta.obj.renderFinish();
}
