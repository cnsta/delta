const std = @import("std");

const wm = &@import("../Delta.zig").instance;
const geom = @import("../util/geom.zig");
const spawn = @import("../spawn.zig").spawn;

const Seat = @import("../Seat.zig");
const Workspace = @import("../Workspace.zig");

const log = std.log.scoped(.action);

pub const Action = union(enum) {
    none,
    spawn: []const []const u8,
    close,
    focus_next,
    focus_direction: geom.Direction,
    focus_workspace: Workspace.Id,
    send_to_workspace: Workspace.Id,
    pointer_move,
    pointer_resize,
    resize: Resize,
    toggle_fullscreen,
    exit,

    pub const Resize = enum {
        grow_width,
        shrink_width,
        grow_height,
        shrink_height,
    };

    pub fn execute(action: Action, seat: *Seat) void {
        switch (action) {
            .none => {},
            .spawn => |argv| spawn(argv),
            .close => seat.closeFocused(),
            .focus_next => seat.focusNext(),
            .focus_direction => |dir| seat.focusDirection(dir),
            .focus_workspace => |id| seat.focusWorkspace(id),
            .send_to_workspace => |id| seat.sendToWorkspace(id),
            .pointer_move => seat.startPointerMove(),
            .pointer_resize => seat.startPointerResize(),
            .resize => |how| seat.resizeStep(how),
            .toggle_fullscreen => seat.toggleFullscreen(),
            .exit => wm.obj.exitSession(),
        }
    }
};
