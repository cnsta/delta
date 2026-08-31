const std = @import("std");

const Action = @import("../input/action.zig").Action;

pub const Request = union(enum) {
    version,
    windows,
    workspaces,
    focused_window,
    outputs,

    action: Action,

    event_stream,
};

pub const Reply = union(enum) {
    ok,

    err: []const u8,

    version: []const u8,
    windows: []const Window,
    workspaces: []const Workspace,
    focused_window: ?Window,
    outputs: []const Output,
};

pub const Window = struct {
    id: []const u8,

    app_id: ?[]const u8,
    title: ?[]const u8,

    workspace: ?u32,

    focused: bool,
    floating: bool,
    fullscreen: bool,
};

pub const Workspace = struct {
    id: u32,

    output: ?[]const u8,

    active: bool,
    focused: bool,
    populated: bool,
};

pub const Event = union(enum) {
    workspaces_changed: []const Workspace,

    windows_changed: []const Window,

    window_focus_changed: ?[]const u8,

    outputs_changed: []const Output,

    workspace_activated: struct {
        id: u32,
        focused: bool,
    },

    config_loaded: struct { failed: bool },
};

pub const Output = struct {
    name: []const u8,
    description: ?[]const u8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    usable: Rect,
    mode: ?Mode,
    scale: i32,
    transform: []const u8,
    workspace: ?u32,
    focused: bool,
};

pub const Mode = struct {
    width: i32,
    height: i32,
    refresh: i32,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

test "a request round-trips through JSON" {
    const gpa = std.testing.allocator;

    const text =
        \\{"action":{"focus_workspace":3}}
    ;

    const parsed = try std.json.parseFromSlice(Request, gpa, text, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 3), parsed.value.action.focus_workspace);
}

test "a reply serialises to one line" {
    const gpa = std.testing.allocator;

    const reply: Reply = .{ .workspaces = &.{
        .{ .id = 1, .output = "DP-3", .active = true, .focused = true, .populated = true },
        .{ .id = 2, .output = null, .active = false, .focused = false, .populated = true },
    } };

    const text = try std.json.Stringify.valueAlloc(gpa, reply, .{});
    defer gpa.free(text);

    // Newline framing only works if the payload contains none.
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "DP-3") != null);
}

test "identical state serialises identically" {
    const gpa = std.testing.allocator;

    const a: []const Window = &.{
        .{
            .id = "abc",
            .app_id = "foot",
            .title = "~",
            .workspace = 1,
            .focused = true,
            .floating = false,
            .fullscreen = false,
        },
    };
    const b = a;

    const first = try std.json.Stringify.valueAlloc(gpa, a, .{});
    defer gpa.free(first);
    const second = try std.json.Stringify.valueAlloc(gpa, b, .{});
    defer gpa.free(second);

    try std.testing.expectEqualStrings(first, second);
}

test "an absent app id is null rather than empty" {
    const gpa = std.testing.allocator;

    const window: Window = .{
        .id = "abc",
        .app_id = null,
        .title = null,
        .workspace = null,
        .focused = false,
        .floating = false,
        .fullscreen = false,
    };

    const text = try std.json.Stringify.valueAlloc(gpa, window, .{});
    defer gpa.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\"app_id\":null") != null);
}
