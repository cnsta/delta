const std = @import("std");

const wm = &@import("../Delta.zig").instance;
const geom = @import("../util/geom.zig");
const spawn = @import("../spawn.zig").spawn;

const Seat = @import("../Seat.zig");
const Workspace = @import("../Workspace.zig");

pub const Action = union(enum) {
    none,
    spawn: []const []const u8,
    close,
    focus_next,
    focus_direction: geom.Direction,
    move_direction: geom.Direction,
    focus_workspace: Workspace.Id,
    send_to_workspace: Workspace.Id,
    pointer_move,
    pointer_resize,
    resize: Resize,
    toggle_fullscreen,
    toggle_split,
    toggle_float,
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
            .toggle_float => seat.toggleFloat(),
            .move_direction => |dir| seat.moveDirection(dir),
            .toggle_split => seat.toggleSplit(),
            .exit => wm.obj.exitSession(),
        }
    }

    pub fn repeats(action: Action) bool {
        return switch (action) {
            .resize, .focus_direction, .focus_next, .move_direction => true,

            .none,
            .spawn,
            .close,
            .focus_workspace,
            .send_to_workspace,
            .pointer_move,
            .pointer_resize,
            .toggle_fullscreen,
            .toggle_float,
            .toggle_split,
            .exit,
            => false,
        };
    }

    pub const Queue = struct {
        pub const capacity = 8;

        buffer: [capacity]Action = [_]Action{.none} ** capacity,
        head: usize = 0,
        len: usize = 0,

        pub fn push(queue: *Queue, action: Action) bool {
            if (queue.len == capacity) return false;

            queue.buffer[(queue.head + queue.len) % capacity] = action;
            queue.len += 1;
            return true;
        }

        pub fn pop(queue: *Queue) ?Action {
            if (queue.len == 0) return null;

            const action = queue.buffer[queue.head];
            queue.head = (queue.head + 1) % capacity;
            queue.len -= 1;
            return action;
        }

        pub fn isEmpty(queue: *const Queue) bool {
            return queue.len == 0;
        }

        pub fn clear(queue: *Queue) void {
            queue.head = 0;
            queue.len = 0;
        }
    };
};

test "Queue preserves order across the wrap" {
    var queue: Action.Queue = .{};

    for (0..Action.Queue.capacity * 5) |i| {
        const action: Action = if (i % 2 == 0) .focus_next else .close;
        try std.testing.expect(queue.push(action));
        try std.testing.expectEqual(std.meta.activeTag(action), std.meta.activeTag(queue.pop().?));
    }

    for (0..5) |_| {
        try std.testing.expect(queue.push(.focus_next));
        try std.testing.expect(queue.push(.close));
        try std.testing.expect(queue.push(.toggle_fullscreen));

        try std.testing.expectEqual(Action.focus_next, queue.pop().?);
        try std.testing.expectEqual(Action.close, queue.pop().?);
        try std.testing.expectEqual(Action.toggle_fullscreen, queue.pop().?);
        try std.testing.expect(queue.isEmpty());
    }
}

test "Queue drops the newest when full" {
    var queue: Action.Queue = .{};

    for (0..Action.Queue.capacity) |_| try std.testing.expect(queue.push(.focus_next));
    try std.testing.expect(!queue.push(.close));

    for (0..Action.Queue.capacity) |_| {
        try std.testing.expectEqual(Action.focus_next, queue.pop().?);
    }
    try std.testing.expectEqual(@as(?Action, null), queue.pop());
}

test "Queue is reusable after clear" {
    var queue: Action.Queue = .{};

    try std.testing.expect(queue.push(.close));
    try std.testing.expect(queue.push(.close));
    queue.clear();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.push(.focus_next));
    try std.testing.expectEqual(Action.focus_next, queue.pop().?);
}
