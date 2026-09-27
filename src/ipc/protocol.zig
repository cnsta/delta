const std = @import("std");

const Action = @import("../input/action.zig").Action;

pub const Request = union(enum) {
    version,
    windows,
    workspaces,
    focused_window,
    outputs,
    layers,

    action: Action,

    event_stream,
};

pub const Reply = union(enum) {
    ok,

    err: []const u8,

    version: []const u8,
    windows: []const WindowInfo,
    workspaces: []const Workspace,
    focused_window: ?WindowInfo,
    outputs: []const OutputInfo,
    layers: []const Layers,

    pub fn jsonStringify(reply: Reply, jws: anytype) !void {
        switch (reply) {
            .ok => try jws.write("ok"),
            inline else => |payload, tag| {
                try jws.beginObject();
                try jws.objectField(@tagName(tag));
                try jws.write(payload);
                try jws.endObject();
            },
        }
    }

    pub fn jsonParse(
        gpa: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Reply {
        if (try source.peekNextTokenType() == .string) {
            _ = try std.json.innerParse(enum { ok }, gpa, source, options);
            return .ok;
        }

        if (try source.next() != .object_begin) return error.UnexpectedToken;

        const name = switch (try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?)) {
            inline .string, .allocated_string => |slice| slice,
            else => return error.UnexpectedToken,
        };

        const result: Reply = inline for (@typeInfo(Reply).@"union".fields) |field| {
            if (!std.mem.eql(u8, field.name, name)) {} else if (field.type == void) {
                if (try source.next() != .object_begin) return error.UnexpectedToken;
                if (try source.next() != .object_end) return error.UnexpectedToken;
                break @unionInit(Reply, field.name, {});
            } else {
                break @unionInit(Reply, field.name, try std.json.innerParse(
                    field.type,
                    gpa,
                    source,
                    options,
                ));
            }
        } else return error.UnknownField;

        if (try source.next() != .object_end) return error.UnexpectedToken;
        return result;
    }
};

pub const Window = struct {
    id: []const u8,

    app_id: ?[]const u8,
    title: ?[]const u8,

    workspace: ?u32,

    focused: bool,
    float: bool,
    fullscreen: bool,
};

pub const WindowInfo = struct {
    id: []const u8,

    app_id: ?[]const u8,
    title: ?[]const u8,

    workspace: ?u32,

    focused: bool,
    float: bool,
    fullscreen: bool,

    output: ?[]const u8 = null,
    pid: ?i32 = null,
    parent: ?[]const u8 = null,

    geometry: ?Rect = null,
    size: ?Size = null,
    min_size: ?Size = null,
    max_size: ?Size = null,

    dialog: bool = false,
    hidden: bool = false,

    decoration: ?[]const u8 = null,
    presentation: ?[]const u8 = null,
    captured: ?u32 = null,
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

    show_desktop: bool,
};

pub const Layers = struct {
    output: []const u8,
    top: i32,
    bottom: i32,
    left: i32,
    right: i32,
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

pub const OutputInfo = struct {
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

    enabled: bool = true,

    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    serial: ?[]const u8 = null,
    physical: ?Size = null,

    fractional_scale: ?f64 = null,
    adaptive_sync: ?bool = null,
    modes: []const ModeInfo = &.{},

    captured: ?u32 = null,
};

pub const Mode = struct {
    width: i32,
    height: i32,
    refresh: i32,
};

pub const ModeInfo = struct {
    width: i32,
    height: i32,
    refresh: i32,
    preferred: bool = false,
    current: bool = false,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Size = struct {
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

test "an ok reply is the bare string ashell expects" {
    const gpa = std.testing.allocator;

    const text = try std.json.Stringify.valueAlloc(gpa, Reply{ .ok = {} }, .{});
    defer gpa.free(text);
    try std.testing.expectEqualStrings("\"ok\"", text);

    const parsed = try std.json.parseFromSlice(Reply, gpa, text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .ok);

    const legacy = try std.json.parseFromSlice(Reply, gpa, "{\"ok\":{}}", .{});
    defer legacy.deinit();
    try std.testing.expect(legacy.value == .ok);
}

test "an err reply is a one-key object ashell expects" {
    const gpa = std.testing.allocator;

    const text = try std.json.Stringify.valueAlloc(gpa, Reply{ .err = "no seat" }, .{});
    defer gpa.free(text);
    try std.testing.expectEqualStrings("{\"err\":\"no seat\"}", text);

    const parsed = try std.json.parseFromSlice(Reply, gpa, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("no seat", parsed.value.err);
}

test "a payload reply keeps its object form" {
    const gpa = std.testing.allocator;

    const text = try std.json.Stringify.valueAlloc(gpa, Reply{ .focused_window = null }, .{});
    defer gpa.free(text);
    try std.testing.expectEqualStrings("{\"focused_window\":null}", text);

    const parsed = try std.json.parseFromSlice(Reply, gpa, text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.focused_window == null);
}

test "an unknown reply tag is rejected" {
    const gpa = std.testing.allocator;

    try std.testing.expectError(
        error.UnknownField,
        std.json.parseFromSlice(Reply, gpa, "{\"nope\":1}", .{}),
    );
    try std.testing.expectError(
        error.InvalidEnumTag,
        std.json.parseFromSlice(Reply, gpa, "\"nope\"", .{}),
    );
}

test "ashell's event_stream request parses" {
    const gpa = std.testing.allocator;

    const parsed = try std.json.parseFromSlice(Request, gpa, "{\"event_stream\":{}}", .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .event_stream);
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
            .float = false,
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
        .float = false,
        .fullscreen = false,
    };

    const text = try std.json.Stringify.valueAlloc(gpa, window, .{});
    defer gpa.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\"app_id\":null") != null);
}

test "windows_changed keeps the shape ashell reads" {
    const gpa = std.testing.allocator;

    const event: Event = .{ .windows_changed = &.{
        .{
            .id = "abc",
            .app_id = "foot",
            .title = "~",
            .workspace = 1,
            .focused = true,
            .float = false,
            .fullscreen = false,
        },
    } };

    const text = try std.json.Stringify.valueAlloc(gpa, event, .{});
    defer gpa.free(text);

    try std.testing.expectEqualStrings(
        "{\"windows_changed\":[{\"id\":\"abc\",\"app_id\":\"foot\",\"title\":\"~\"," ++
            "\"workspace\":1,\"focused\":true,\"float\":false,\"fullscreen\":false}]}",
        text,
    );
}

test "a windows reply from an older delta still parses" {
    const gpa = std.testing.allocator;

    const text =
        \\{"windows":[{"id":"abc","app_id":null,"title":"~","workspace":2,"focused":false,"float":true,"fullscreen":false}]}
    ;

    const parsed = try std.json.parseFromSlice(Reply, gpa, text, .{});
    defer parsed.deinit();

    const window = parsed.value.windows[0];
    try std.testing.expect(window.float);
    try std.testing.expect(window.geometry == null);
    try std.testing.expect(window.captured == null);
    try std.testing.expect(!window.dialog);
}

test "window details round-trip" {
    const gpa = std.testing.allocator;

    const reply: Reply = .{ .focused_window = .{
        .id = "abc",
        .app_id = "foot",
        .title = null,
        .workspace = 1,
        .focused = true,
        .float = true,
        .fullscreen = false,
        .output = "DP-3",
        .pid = 42,
        .geometry = .{ .x = 10, .y = 40, .width = 800, .height = 600 },
        .size = .{ .width = 800, .height = 600 },
        .min_size = .{ .width = 400, .height = 300 },
        .decoration = "prefers-ssd",
        .captured = 1,
    } };

    const text = try std.json.Stringify.valueAlloc(gpa, reply, .{});
    defer gpa.free(text);

    const parsed = try std.json.parseFromSlice(Reply, gpa, text, .{});
    defer parsed.deinit();

    const window = parsed.value.focused_window.?;
    try std.testing.expectEqual(@as(?i32, 42), window.pid);
    try std.testing.expectEqual(@as(i32, 40), window.geometry.?.y);
    try std.testing.expectEqual(@as(i32, 300), window.min_size.?.height);
    try std.testing.expect(window.max_size == null);
    try std.testing.expectEqualStrings("DP-3", window.output.?);
}

test "outputs_changed keeps the shape ashell reads" {
    const gpa = std.testing.allocator;

    const event: Event = .{ .outputs_changed = &.{
        .{
            .name = "DP-3",
            .description = null,
            .x = 0,
            .y = 0,
            .width = 2560,
            .height = 1440,
            .usable = .{ .x = 0, .y = 30, .width = 2560, .height = 1410 },
            .mode = .{ .width = 2560, .height = 1440, .refresh = 239970 },
            .scale = 1,
            .transform = "normal",
            .workspace = 1,
            .focused = true,
        },
    } };

    const text = try std.json.Stringify.valueAlloc(gpa, event, .{});
    defer gpa.free(text);

    try std.testing.expectEqualStrings(
        "{\"outputs_changed\":[{\"name\":\"DP-3\",\"description\":null,\"x\":0,\"y\":0," ++
            "\"width\":2560,\"height\":1440," ++
            "\"usable\":{\"x\":0,\"y\":30,\"width\":2560,\"height\":1410}," ++
            "\"mode\":{\"width\":2560,\"height\":1440,\"refresh\":239970}," ++
            "\"scale\":1,\"transform\":\"normal\",\"workspace\":1,\"focused\":true}]}",
        text,
    );
}

test "an outputs reply from an older delta still parses" {
    const gpa = std.testing.allocator;

    const text =
        \\{"outputs":[{"name":"DP-3","description":null,"x":0,"y":0,"width":2560,"height":1440,"usable":{"x":0,"y":0,"width":2560,"height":1440},"mode":null,"scale":1,"transform":"normal","workspace":1,"focused":true}]}
    ;

    const parsed = try std.json.parseFromSlice(Reply, gpa, text, .{});
    defer parsed.deinit();

    const output = parsed.value.outputs[0];
    try std.testing.expect(output.enabled);
    try std.testing.expect(output.adaptive_sync == null);
    try std.testing.expect(output.fractional_scale == null);
    try std.testing.expectEqual(@as(usize, 0), output.modes.len);
}

test "output details round-trip" {
    const gpa = std.testing.allocator;

    const reply: Reply = .{ .outputs = &.{
        .{
            .name = "DP-3",
            .description = "Samsung",
            .x = 0,
            .y = 0,
            .width = 2048,
            .height = 1152,
            .usable = .{ .x = 0, .y = 0, .width = 2048, .height = 1152 },
            .mode = .{ .width = 2560, .height = 1440, .refresh = 239970 },
            .scale = 2,
            .transform = "normal",
            .workspace = 1,
            .focused = true,
            .make = "Samsung Electric Company",
            .physical = .{ .width = 600, .height = 340 },
            .fractional_scale = 1.25,
            .adaptive_sync = false,
            .modes = &.{
                .{ .width = 2560, .height = 1440, .refresh = 239970, .preferred = true, .current = true },
                .{ .width = 2560, .height = 1440, .refresh = 143998 },
            },
            .captured = 0,
        },
        .{
            .name = "HDMI-A-1",
            .description = null,
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .usable = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .mode = null,
            .scale = 1,
            .transform = "normal",
            .workspace = null,
            .focused = false,
            .enabled = false,
        },
    } };

    const text = try std.json.Stringify.valueAlloc(gpa, reply, .{});
    defer gpa.free(text);

    const parsed = try std.json.parseFromSlice(Reply, gpa, text, .{});
    defer parsed.deinit();

    const output = parsed.value.outputs[0];
    try std.testing.expectEqual(@as(?f64, 1.25), output.fractional_scale);
    try std.testing.expectEqual(@as(?bool, false), output.adaptive_sync);
    try std.testing.expectEqual(@as(usize, 2), output.modes.len);
    try std.testing.expect(output.modes[0].current and output.modes[0].preferred);
    try std.testing.expect(!output.modes[1].current);
    try std.testing.expectEqual(@as(i32, 340), output.physical.?.height);
    try std.testing.expect(!parsed.value.outputs[1].enabled);
}
