const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const geom = @import("util/geom.zig");
const list = @import("util/list.zig");

const Seat = @import("Seat.zig");
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
