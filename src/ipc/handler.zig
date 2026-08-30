const std = @import("std");

const wm = &@import("../Delta.zig").instance;
const protocol = @import("protocol.zig");
const snapshot = @import("snapshot.zig");

const cli = @import("../cli.zig");

const log = std.log.scoped(.ipc);

pub fn handle(request: []const u8, streaming: *bool) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(wm.gpa);
    defer arena.deinit();

    const line = reply(arena.allocator(), request, streaming) catch |err| {
        log.warn("failed to answer an IPC request: {t}", .{err});
        return "{\"err\":\"internal error\"}";
    };

    return line;
}

fn reply(arena: std.mem.Allocator, request: []const u8, streaming: *bool) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(
        protocol.Request,
        arena,
        request,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return try stringify(arena, protocol.Reply{ .err = "malformed request" });
    };

    switch (parsed) {
        .version => return try stringify(arena, protocol.Reply{ .version = cli.version }),

        .windows => {
            const state = try snapshot.build(arena);
            return try stringify(arena, protocol.Reply{ .windows = state.windows });
        },

        .workspaces => {
            const state = try snapshot.build(arena);
            return try stringify(arena, protocol.Reply{ .workspaces = state.workspaces });
        },

        .outputs => {
            const state = try snapshot.build(arena);
            return try stringify(arena, protocol.Reply{ .outputs = state.outputs });
        },

        .focused_window => {
            const state = try snapshot.build(arena);

            var found: ?protocol.Window = null;
            for (state.windows) |window| {
                if (window.focused) found = window;
            }

            return try stringify(arena, protocol.Reply{ .focused_window = found });
        },

        .action => |action| {
            // TODO: multi-seat
            const seat = wm.seats.first() orelse {
                return try stringify(arena, protocol.Reply{ .err = "no seat" });
            };

            if (!seat.pending.push(action)) {
                return try stringify(arena, protocol.Reply{ .err = "action queue is full" });
            }
            wm.dirty = true;

            return try stringify(arena, protocol.Reply.ok);
        },

        .event_stream => {
            streaming.* = true;

            wm.ipc_last.clearRetainingCapacity();
            wm.dirty = true;

            return try stringify(arena, protocol.Reply.ok);
        },
    }
}

fn stringify(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{});
}
