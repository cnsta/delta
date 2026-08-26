const std = @import("std");

const wm = &@import("../Delta.zig").instance;

const Seat = @import("../Seat.zig");

const log = std.log.scoped(.action);

pub const Action = union(enum) {
    none,
    spawn: []const []const u8,
    close,
    focus_next,
    move,
    resize,
    exit,

    pub fn execute(action: Action, seat: *Seat) void {
        switch (action) {
            .none => {},
            .spawn => |argv| spawn(argv),
            .close => seat.closeFocused(),
            .focus_next => seat.focusNext(),
            .move => seat.startPointerMove(),
            .resize => seat.startPointerResize(),
            .exit => wm.obj.exitSession(),
        }
    }
};

fn spawn(argv: []const []const u8) void {
    std.debug.assert(argv.len > 0);
    _ = std.process.spawn(wm.io, .{ .argv = argv }) catch |err| {
        log.err("failed to spawn {s}: {s}", .{ argv[0], @errorName(err) });
    };
}
