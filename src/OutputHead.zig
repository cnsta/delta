const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const string = @import("util/string.zig");

const OutputHead = @This();

obj: *zwlr.OutputHeadV1,
link: wl.list.Link,

name: ?[]const u8 = null,
description: ?[]const u8 = null,
make: ?[]const u8 = null,
model: ?[]const u8 = null,
serial: ?[]const u8 = null,

physical: ?struct { width: i32, height: i32 } = null,
enabled: bool = false,

modes: std.ArrayList(*Mode) = .empty,
current: ?*Mode = null,

scale: f64 = 1,
adaptive_sync: ?bool = null,

pub const Mode = struct {
    obj: *zwlr.OutputModeV1,
    head: *OutputHead,

    width: i32 = 0,
    height: i32 = 0,
    /// mHz, zero when the compositor doesn't know.
    refresh: i32 = 0,
    preferred: bool = false,

    fn destroy(mode: *Mode) void {
        if (!wm.shutting_down) release(mode.obj);
        wm.gpa.destroy(mode);
    }
};

pub fn managerListener(
    manager: *zwlr.OutputManagerV1,
    event: zwlr.OutputManagerV1.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .head => |args| create(args.head),
        .done => {},
        .finished => {
            manager.destroy();
            wm.output_manager = null;
        },
    }
}

fn create(obj: *zwlr.OutputHeadV1) void {
    const head = wm.gpa.create(OutputHead) catch fatal("Out of memory.", .{});
    head.* = .{ .obj = obj, .link = undefined };

    obj.setListener(*OutputHead, listener, head);
    wm.heads.append(head);
}

pub fn destroy(head: *OutputHead) void {
    for (head.modes.items) |mode| mode.destroy();
    head.modes.deinit(wm.gpa);

    inline for (.{ "name", "description", "make", "model", "serial" }) |field| {
        string.free(wm.gpa, &@field(head, field));
    }

    if (!wm.shutting_down) release(head.obj);

    head.link.remove();
    wm.gpa.destroy(head);
}

/// the head behind the wl_output of this name.
pub fn find(name: []const u8) ?*OutputHead {
    var it = wm.heads.iterator(.forward);
    while (it.next()) |head| {
        const head_name = head.name orelse continue;
        if (std.mem.eql(u8, head_name, name)) return head;
    }
    return null;
}

/// `release` only exists from v3, before that the proxy is simply dropped.
fn release(obj: anytype) void {
    if (obj.getVersion() >= 3) obj.release() else obj.destroy();
}

fn listener(_: *zwlr.OutputHeadV1, event: zwlr.OutputHeadV1.Event, head: *OutputHead) void {
    switch (event) {
        .name => |args| setString(&head.name, args.name),
        .description => |args| setString(&head.description, args.description),
        .make => |args| setString(&head.make, args.make),
        .model => |args| setString(&head.model, args.model),
        .serial_number => |args| setString(&head.serial, args.serial_number),

        .physical_size => |args| head.physical = if (args.width > 0 and args.height > 0)
            .{ .width = args.width, .height = args.height }
        else
            null,

        .enabled => |args| head.enabled = args.enabled != 0,

        .mode => |args| {
            const mode = wm.gpa.create(Mode) catch fatal("Out of memory.", .{});
            mode.* = .{ .obj = args.mode, .head = head };

            head.modes.append(wm.gpa, mode) catch fatal("Out of memory.", .{});
            args.mode.setListener(*Mode, modeListener, mode);
        },

        .current_mode => |args| {
            head.current = if (args.mode) |obj| @ptrCast(@alignCast(obj.getUserData())) else null;
        },

        .scale => |args| head.scale = args.scale.toDouble(),

        .adaptive_sync => |args| head.adaptive_sync = switch (args.state) {
            .enabled => true,
            .disabled => false,
            _ => null,
        },

        // only the layout's own view of these matters, and river_output_v1
        // already reports it.
        .position, .transform => {},

        .finished => head.destroy(),
    }
}

fn modeListener(_: *zwlr.OutputModeV1, event: zwlr.OutputModeV1.Event, mode: *Mode) void {
    switch (event) {
        .size => |args| {
            mode.width = args.width;
            mode.height = args.height;
        },
        .refresh => |args| mode.refresh = args.refresh,
        .preferred => mode.preferred = true,

        .finished => {
            const head = mode.head;
            if (head.current == mode) head.current = null;

            for (head.modes.items, 0..) |item, i| {
                if (item != mode) continue;
                _ = head.modes.orderedRemove(i);
                break;
            }

            mode.destroy();
        },
    }
}

fn setString(owned: *?[]const u8, value: [*:0]const u8) void {
    _ = string.replace(wm.gpa, owned, value) catch fatal("Out of memory.", .{});
}
