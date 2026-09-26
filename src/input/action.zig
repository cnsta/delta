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
    show_desktop,
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
            .spawn => |argv| if (!wm.desktop_shown) spawn(argv),
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
            .show_desktop => wm.toggleShowDesktop(),
            .exit => wm.obj.exitSession(),
        }
    }

    pub const ParseError = error{
        UnknownAction,
        MissingArgument,
        InvalidArgument,
        TooManyArguments,
    };

    pub fn fromArgs(args: []const []const u8) ParseError!Action {
        if (args.len == 0) return error.MissingArgument;

        const tag = std.meta.stringToEnum(std.meta.Tag(Action), args[0]) orelse
            return error.UnknownAction;
        const rest = args[1..];

        switch (tag) {
            inline else => |t| {
                const name = @tagName(t);
                const Payload = @FieldType(Action, name);

                if (Payload == void) {
                    if (rest.len > 0) return error.TooManyArguments;
                    return @unionInit(Action, name, {});
                } else if (Payload == []const []const u8) {
                    if (rest.len == 0) return error.MissingArgument;
                    return @unionInit(Action, name, rest);
                } else {
                    if (rest.len == 0) return error.MissingArgument;
                    if (rest.len > 1) return error.TooManyArguments;

                    const value: Payload = switch (@typeInfo(Payload)) {
                        .@"enum" => std.meta.stringToEnum(Payload, rest[0]) orelse
                            return error.InvalidArgument,
                        .int => std.fmt.parseInt(Payload, rest[0], 10) catch
                            return error.InvalidArgument,
                        else => @compileError("no command-line form for ." ++ name),
                    };
                    return @unionInit(Action, name, value);
                }
            },
        }
    }

    pub const listing = blk: {
        var text: []const u8 = "";
        for (std.meta.fields(Action)) |field| {
            if (std.mem.eql(u8, field.name, "none")) continue;
            text = text ++ "  " ++ field.name ++ argHint(field.type) ++ "\n";
        }
        break :blk text;
    };

    fn argHint(comptime T: type) []const u8 {
        if (T == void) return "";
        if (T == []const []const u8) return " <command> [args...]";

        return switch (@typeInfo(T)) {
            .@"enum" => |info| blk: {
                var hint: []const u8 = " <";
                for (info.fields, 0..) |field, i| {
                    if (i > 0) hint = hint ++ "|";
                    hint = hint ++ field.name;
                }
                break :blk hint ++ ">";
            },
            .int => " <n>",
            else => @compileError("no argument hint for " ++ @typeName(T)),
        };
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
            .show_desktop,
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

test "fromArgs parses every kind of payload" {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(Action.close, try Action.fromArgs(&.{"close"}));
    try expectEqual(
        geom.Direction.left,
        (try Action.fromArgs(&.{ "focus_direction", "left" })).focus_direction,
    );
    try expectEqual(
        Action.Resize.grow_height,
        (try Action.fromArgs(&.{ "resize", "grow_height" })).resize,
    );
    try expectEqual(
        @as(Workspace.Id, 7),
        (try Action.fromArgs(&.{ "send_to_workspace", "7" })).send_to_workspace,
    );

    // Flags after the command belong to it, not to delctl.
    const argv = (try Action.fromArgs(&.{ "spawn", "foot", "-e", "htop" })).spawn;
    try expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("-e", argv[1]);
}

test "fromArgs rejects bad input" {
    const expectError = std.testing.expectError;

    try expectError(error.MissingArgument, Action.fromArgs(&.{}));
    try expectError(error.UnknownAction, Action.fromArgs(&.{"toggle_floating"}));
    try expectError(error.MissingArgument, Action.fromArgs(&.{"focus_workspace"}));
    try expectError(error.MissingArgument, Action.fromArgs(&.{"spawn"}));
    try expectError(error.InvalidArgument, Action.fromArgs(&.{ "focus_workspace", "x" }));
    try expectError(error.InvalidArgument, Action.fromArgs(&.{ "focus_workspace", "-1" }));
    try expectError(error.InvalidArgument, Action.fromArgs(&.{ "focus_direction", "north" }));
    try expectError(error.TooManyArguments, Action.fromArgs(&.{ "close", "now" }));
    try expectError(error.TooManyArguments, Action.fromArgs(&.{ "resize", "grow_width", "2" }));
}

test "listing covers every action but none" {
    inline for (std.meta.fields(Action)) |field| {
        const found = std.mem.indexOf(u8, Action.listing, "  " ++ field.name) != null;
        try std.testing.expectEqual(!std.mem.eql(u8, field.name, "none"), found);
    }
    try std.testing.expect(std.mem.indexOf(u8, Action.listing, "focus_direction <left|") != null);
}
