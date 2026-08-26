const std = @import("std");

const wm = &@import("../Delta.zig").instance;

const Seat = @import("../Seat.zig");
const Workspace = @import("../Workspace.zig");

const log = std.log.scoped(.action);

pub const Action = union(enum) {
    none,
    spawn: []const []const u8,
    close,
    focus_next,
    focus_workspace: Workspace.Id,
    send_to_workspace: Workspace.Id,
    move,
    resize,
    exit,

    pub fn execute(action: Action, seat: *Seat) void {
        switch (action) {
            .none => {},
            .spawn => |argv| spawn(argv),
            .close => seat.closeFocused(),
            .focus_next => seat.focusNext(),
            .focus_workspace => |id| seat.focusWorkspace(id),
            .send_to_workspace => |id| seat.sendToWorkspace(id),
            .move => seat.startPointerMove(),
            .resize => seat.startPointerResize(),
            .exit => wm.obj.exitSession(),
        }
    }
};

fn spawn(argv: []const []const u8) void {
    std.debug.assert(argv.len > 0);

    log.info("spawning {s}", .{argv[0]});
    _ = std.process.spawn(wm.io, .{ .argv = argv }) catch |err| {
        log.err("failed to spawn {s}: {s}", .{ argv[0], @errorName(err) });
    };
}
