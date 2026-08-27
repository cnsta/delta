const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const geom = @import("util/geom.zig");
const list = @import("util/list.zig");

const Seat = @import("Seat.zig");
const Window = @import("Window.zig");
const Workspace = @import("Workspace.zig");

const Output = @This();

obj: *river.OutputV1,
removed: bool = false,
link: wl.list.Link,

x: i32 = 0,
y: i32 = 0,
width: i32 = 0,
height: i32 = 0,

workspace: *Workspace,
shell: ?*river.LayerShellOutputV1 = null,
usable: ?geom.Rect = null,
previous: ?*Workspace = null,

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
        window.slot = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        window.placed = null;
    }

    if (wm.default_output == output) wm.default_output = null;

    if (output.shell) |shell| shell.destroy();

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

pub fn usableArea(output: *const Output) geom.Rect {
    return output.usable orelse .{
        .x = output.x,
        .y = output.y,
        .width = output.width,
        .height = output.height,
    };
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

pub fn contains(output: *const Output, point: geom.Point) bool {
    return point.x >= output.x and point.x < output.x + output.width and
        point.y >= output.y and point.y < output.y + output.height;
}

pub fn at(point: geom.Point) ?*Output {
    var it = wm.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.contains(point)) return output;
    }
    return null;
}

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
        else => {},
    }
}
