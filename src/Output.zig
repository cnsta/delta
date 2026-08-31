const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const geom = @import("util/geom.zig");
const list = @import("util/list.zig");
const string = @import("util/string.zig");

const Seat = @import("Seat.zig");
const Window = @import("Window.zig");
const Workspace = @import("Workspace.zig");

const Output = @This();

obj: *river.OutputV1,
link: wl.list.Link,
removed: bool = false,

x: i32 = 0,
y: i32 = 0,
width: i32 = 0,
height: i32 = 0,

usable: ?geom.Rect = null,

workspace: *Workspace,

previous: ?*Workspace = null,

shell: ?*river.LayerShellOutputV1 = null,

name: ?[]const u8 = null,
wl_output: ?*wl.Output = null,
description: ?[]const u8 = null,
mode: ?Mode = null,
scale: i32 = 1,
transform: wl.Output.Transform = .normal,

pub const Mode = struct {
    width: i32,
    height: i32,
    refresh: i32,
};

pub fn create(river_output: *river.OutputV1) void {
    const output = wm.gpa.create(Output) catch fatal("Out of memory.", .{});
    const workspace = Workspace.firstUnmapped();

    output.* = .{
        .obj = river_output,
        .link = undefined,
        .workspace = workspace,
    };
    workspace.output = output;

    output.obj.setListener(*Output, listener, output);
    wm.outputs.append(output);

    if (wm.layer_shell) |layer_shell| {
        const shell = layer_shell.getOutput(river_output) catch fatal("Out of memory.", .{});
        output.shell = shell;
        shell.setListener(*Output, shellListener, output);
    }
}

pub fn fromObj(obj: *river.OutputV1) *Output {
    return @ptrCast(@alignCast(obj.getUserData()));
}

pub fn maybeDestroy(output: *Output) void {
    if (!output.removed) return;

    string.free(wm.gpa, &output.name);
    if (output.wl_output) |obj| obj.release();

    output.workspace.output = null;
    output.previous = null;

    var seats = list.safeIterator(Seat, .link, &wm.seats);
    while (seats.next()) |seat| seat.forgetOutput(output);

    var windows = list.safeIterator(Window, .link, &wm.windows);
    while (windows.next()) |window| {
        if (window.fullscreen != output and window.fullscreen_applied != output) continue;

        window.obj.informNotFullscreen();
        window.fullscreen = null;
        window.fullscreen_applied = null;
        window.slot = geom.Rect.zero;
        window.placed = null;
    }

    if (wm.default_output == output) wm.default_output = null;

    if (output.shell) |shell| shell.destroy();

    string.free(wm.gpa, &output.name);

    if (output.wl_output) |obj| obj.release();

    output.obj.destroy();
    output.link.remove();
    wm.gpa.destroy(output);
}

pub fn setWorkspace(output: *Output, target: *Workspace) void {
    std.debug.assert(target.output == null or target.output == output);
    if (output.workspace == target) return;

    const outgoing = output.workspace;
    outgoing.output = null;
    output.previous = outgoing;

    output.workspace = target;
    target.output = output;
}

// -- queries -------------------------------------------------------------

pub fn rect(output: *const Output) geom.Rect {
    return .{
        .x = output.x,
        .y = output.y,
        .width = output.width,
        .height = output.height,
    };
}

pub fn usableArea(output: *const Output) geom.Rect {
    return output.usable orelse output.rect();
}

pub fn contains(output: *const Output, point: geom.Point) bool {
    return output.rect().contains(point);
}

pub fn at(point: geom.Point) ?*Output {
    var it = wm.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.contains(point)) return output;
    }
    return null;
}

// -- listeners -----------------------------------------------------------

fn listener(_: *river.OutputV1, event: river.OutputV1.Event, output: *Output) void {
    switch (event) {
        .removed => output.removed = true,
        .position => |args| {
            output.x = args.x;
            output.y = args.y;
        },
        .dimensions => |args| {
            output.width = args.width;
            output.height = args.height;
        },

        .wl_output => |args| {
            const obj = wm.registry.bind(args.name, wl.Output, 4) catch
                fatal("Out of memory.", .{});

            output.wl_output = obj;
            obj.setListener(*Output, wlOutputListener, output);
        },
    }
}

fn shellListener(
    _: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    output: *Output,
) void {
    switch (event) {
        .non_exclusive_area => |args| output.usable = .{
            .x = args.x,
            .y = args.y,
            .width = args.width,
            .height = args.height,
        },
    }
}

fn wlOutputListener(_: *wl.Output, event: wl.Output.Event, output: *Output) void {
    switch (event) {
        .geometry => |args| {
            output.transform = args.transform;
        },

        .description => |args| _ = string.replace(wm.gpa, &output.description, args.description) catch
            fatal("Out of memory.", .{}),

        .mode => |args| {
            if (!args.flags.current) return;

            output.mode = .{
                .width = args.width,
                .height = args.height,
                .refresh = args.refresh,
            };
        },

        .scale => |args| output.scale = args.factor,

        .name => |args| _ = string.replace(wm.gpa, &output.name, args.name) catch
            fatal("Out of memory.", .{}),

        else => {},
    }
}
