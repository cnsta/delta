const std = @import("std");

const wm = &@import("../Delta.zig").instance;
const list = @import("../util/list.zig");
const protocol = @import("protocol.zig");

const Output = @import("../Output.zig");
const Window = @import("../Window.zig");
const Workspace = @import("../Workspace.zig");

const Allocator = std.mem.Allocator;

pub const State = struct {
    windows: []const protocol.Window,
    workspaces: []const protocol.Workspace,
    outputs: []const protocol.Output,
};

pub fn build(arena: Allocator) !State {
    return .{
        .windows = try windows(arena),
        .workspaces = try workspaces(arena),
        .outputs = try outputs(arena),
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
            .floating = window.floating,
            .fullscreen = window.fullscreen != null,
        });
    }

    return out.items;
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

        try out.append(arena, .{
            .name = name,
            .workspace = output.workspace.id,
            .focused = focusedOutput() == output,
        });
    }

    return out.items;
}

/// TODO: multi-seat
fn focusedWorkspace() ?*Workspace {
    const seat = wm.seats.first() orelse return null;
    return seat.workspace();
}

fn focusedOutput() ?*Output {
    const seat = wm.seats.first() orelse return null;
    return seat.output;
}
