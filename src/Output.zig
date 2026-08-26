const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const geom = @import("util/geom.zig");
const list = @import("util/list.zig");

const Output = @This();

obj: *river.OutputV1,
removed: bool = false,
link: wl.list.Link,

x: i32 = 0,
y: i32 = 0,
width: i32 = 0,
height: i32 = 0,

pub fn create(river_output: *river.OutputV1) void {
    const output = wm.gpa.create(Output) catch fatal("Out of memory.", .{});

    output.* = .{
        .obj = river_output,
        .link = undefined,
    };

    output.obj.setListener(*Output, listener, output);
    wm.outputs.append(output);
}

pub fn fromObj(obj: *river.OutputV1) *Output {
    return @ptrCast(@alignCast(obj.getUserData()));
}

pub fn maybeDestroy(output: *Output) void {
    if (!output.removed) return;

    output.workspace.output = null;
    output.workspace.syncPositions();
    output.previous = null;

    output.obj.destroy();
    output.link.remove();
    wm.gpa.destroy(output);
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
            output.workspace.syncPositions();
        },
        .dimensions => |args| {
            output.width = args.width;
            output.height = args.height;
        },
        else => {},
    }
}
