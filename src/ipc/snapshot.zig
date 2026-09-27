const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const wm = &@import("../Delta.zig").instance;
const list = @import("../util/list.zig");
const protocol = @import("protocol.zig");

const Output = @import("../Output.zig");
const OutputHead = @import("../OutputHead.zig");
const Window = @import("../Window.zig");
const Workspace = @import("../Workspace.zig");

const Allocator = std.mem.Allocator;

pub const State = struct {
    windows: []const protocol.Window,
    workspaces: []const protocol.Workspace,
    outputs: []const protocol.Output,
    layers: []const protocol.Layers,
};

pub fn build(arena: Allocator) !State {
    return .{
        .windows = try windows(arena),
        .workspaces = try workspaces(arena),
        .outputs = try outputs(arena),
        .layers = try layers(arena),
    };
}

fn windows(arena: Allocator) ![]const protocol.Window {
    var out: std.ArrayList(protocol.Window) = .empty;

    var it = wm.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.identifier().len == 0) continue;

        try out.append(arena, .{
            .id = window.identifier(),
            .app_id = window.app_id,
            .title = window.title,
            .workspace = if (window.workspace) |ws| ws.id else null,
            .focused = window.focus_count > 0,
            .float = window.float,
            .fullscreen = window.fullscreen != null,
        });
    }

    return out.items;
}

pub fn windowInfos(arena: Allocator) ![]const protocol.WindowInfo {
    var out: std.ArrayList(protocol.WindowInfo) = .empty;

    var it = wm.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.identifier().len == 0) continue;

        const output = window.fullscreen orelse if (window.workspace) |ws| ws.output else null;

        try out.append(arena, .{
            .id = window.identifier(),
            .app_id = window.app_id,
            .title = window.title,
            .workspace = if (window.workspace) |ws| ws.id else null,
            .focused = window.focus_count > 0,
            .float = window.float,
            .fullscreen = window.fullscreen != null,

            .output = if (output) |o| o.name else null,
            .pid = window.pid,
            .parent = if (window.parent) |p| p.identifier() else null,

            .geometry = geometry(window),
            .size = size(window.width, window.height),
            .min_size = size(window.limits.min.width, window.limits.min.height),
            .max_size = size(window.limits.max.width, window.limits.max.height),

            .dialog = window.isDialog(),
            .hidden = window.hidden,

            .decoration = if (window.decoration_hint) |h| decorationName(h) else null,
            .presentation = if (window.presentation_hint) |h| presentationName(h) else null,
            .captured = window.capture_sessions,
        });
    }

    return out.items;
}

fn geometry(window: *const Window) ?protocol.Rect {
    if (window.fullscreen) |output| {
        return .{ .x = output.x, .y = output.y, .width = output.width, .height = output.height };
    }

    const ws = window.workspace orelse return null;
    const output = ws.output orelse return null;
    if (window.slot.width == 0 or window.slot.height == 0) return null;

    return .{
        .x = output.x + window.slot.x,
        .y = output.y + window.slot.y,
        .width = window.slot.width,
        .height = window.slot.height,
    };
}

fn size(width: i32, height: i32) ?protocol.Size {
    if (width <= 0 and height <= 0) return null;
    return .{ .width = width, .height = height };
}

fn decorationName(hint: river.WindowV1.DecorationHint) []const u8 {
    return switch (hint) {
        .only_supports_csd => "csd-only",
        .prefers_csd => "prefers-csd",
        .prefers_ssd => "prefers-ssd",
        .no_preference => "no-preference",

        _ => "unknown",
    };
}

fn presentationName(hint: river.OutputV1.PresentationMode) []const u8 {
    return switch (hint) {
        .vsync => "vsync",
        .async => "async",

        _ => "unknown",
    };
}

fn workspaces(arena: Allocator) ![]const protocol.Workspace {
    var out: std.ArrayList(protocol.Workspace) = .empty;

    var it = wm.workspaces.iterator(.forward);
    while (it.next()) |workspace| {
        try out.append(arena, .{
            .id = workspace.id,
            .output = if (workspace.output) |o| o.name else null,
            .active = workspace.output != null,
            .focused = focusedWorkspace() == workspace,
            .populated = workspace.windows.first() != null,
        });
    }

    return out.items;
}

fn outputs(arena: Allocator) ![]const protocol.Output {
    var out: std.ArrayList(protocol.Output) = .empty;

    var it = wm.outputs.iterator(.forward);
    while (it.next()) |output| {
        const name = output.name orelse continue;

        const usable = output.usableArea();

        try out.append(arena, .{
            .name = name,
            .description = output.description,

            .x = output.x,
            .y = output.y,
            .width = output.width,
            .height = output.height,

            .usable = .{
                .x = usable.x,
                .y = usable.y,
                .width = usable.width,
                .height = usable.height,
            },

            .mode = if (output.mode) |m| .{
                .width = m.width,
                .height = m.height,
                .refresh = m.refresh,
            } else null,

            .scale = output.scale,
            .transform = transformName(output.transform),

            .workspace = output.workspace.id,
            .focused = focusedOutput() == output,
        });
    }

    return out.items;
}

pub fn outputInfos(arena: Allocator) ![]const protocol.OutputInfo {
    var out: std.ArrayList(protocol.OutputInfo) = .empty;

    for (try outputs(arena)) |output| {
        var info: protocol.OutputInfo = .{
            .name = output.name,
            .description = output.description,
            .x = output.x,
            .y = output.y,
            .width = output.width,
            .height = output.height,
            .usable = output.usable,
            .mode = output.mode,
            .scale = output.scale,
            .transform = output.transform,
            .workspace = output.workspace,
            .focused = output.focused,
        };

        if (findOutput(output.name)) |o| info.captured = o.capture_sessions;
        if (OutputHead.find(output.name)) |head| try addHead(arena, &info, head);

        try out.append(arena, info);
    }

    var it = wm.heads.iterator(.forward);
    while (it.next()) |head| {
        if (head.enabled) continue;
        const name = head.name orelse continue;

        var info: protocol.OutputInfo = .{
            .name = name,
            .description = head.description,
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
        };
        try addHead(arena, &info, head);

        try out.append(arena, info);
    }

    return out.items;
}

fn addHead(arena: Allocator, info: *protocol.OutputInfo, head: *const OutputHead) !void {
    info.enabled = head.enabled;
    info.make = head.make;
    info.model = head.model;
    info.serial = head.serial;
    if (head.physical) |p| info.physical = .{ .width = p.width, .height = p.height };
    info.fractional_scale = head.scale;
    info.adaptive_sync = head.adaptive_sync;

    const modes = try arena.alloc(protocol.ModeInfo, head.modes.items.len);
    for (head.modes.items, modes) |mode, *m| {
        m.* = .{
            .width = mode.width,
            .height = mode.height,
            .refresh = mode.refresh,
            .preferred = mode.preferred,
            .current = head.current == mode,
        };
    }
    info.modes = modes;
}

fn findOutput(name: []const u8) ?*Output {
    var it = wm.outputs.iterator(.forward);
    while (it.next()) |output| {
        const output_name = output.name orelse continue;
        if (std.mem.eql(u8, output_name, name)) return output;
    }
    return null;
}

fn layers(arena: Allocator) ![]const protocol.Layers {
    var out: std.ArrayList(protocol.Layers) = .empty;

    var it = wm.outputs.iterator(.forward);
    while (it.next()) |output| {
        const name = output.name orelse continue;
        const m = output.layerMargins();

        try out.append(arena, .{
            .output = name,
            .top = m.top,
            .bottom = m.bottom,
            .left = m.left,
            .right = m.right,
        });
    }

    return out.items;
}

fn transformName(transform: wl.Output.Transform) []const u8 {
    return switch (transform) {
        .normal => "normal",
        .@"90" => "90",
        .@"180" => "180",
        .@"270" => "270",
        .flipped => "flipped",
        .flipped_90 => "flipped-90",
        .flipped_180 => "flipped-180",
        .flipped_270 => "flipped-270",

        _ => "unknown",
    };
}

fn focusedWorkspace() ?*Workspace {
    const seat = wm.activeSeat() orelse return null;
    return seat.workspace();
}

fn focusedOutput() ?*Output {
    const seat = wm.activeSeat() orelse return null;
    return seat.output;
}
