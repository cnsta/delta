const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const Delta = @import("Delta.zig");

const wm_version = 4;
const xkb_bindings_version = 3;

const Globals = struct {
    window_manager: ?*river.WindowManagerV1 = null,
    xkb_bindings: ?*river.XkbBindingsV1 = null,
};

pub fn main(init: std.process.Init) !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    var globals: Globals = .{};
    const registry = try display.getRegistry();
    registry.setListener(*Globals, registryListener, &globals);

    if (display.roundtrip() != .SUCCESS) fatal("Roundtrip failed.", .{});

    Delta.init(
        init.gpa,
        init.io,
        globals.window_manager orelse
            fatal("river_window_manager_v1 not supported by the Wayland server.", .{}),
        globals.xkb_bindings orelse
            fatal("river_xkb_bindings_v1 not supported by the Wayland server.", .{}),
    );

    std.log.info("delta connected to river; wm v{d}, xkb-bindings v{d}", .{
        wm_version, xkb_bindings_version,
    });

    while (true) {
        if (display.dispatch() != .SUCCESS) fatal("Dispatch failed.", .{});
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |ev| {
            if (std.mem.orderZ(u8, river.WindowManagerV1.interface.name, ev.interface) == .eq) {
                if (ev.version < wm_version) {
                    fatal("Expected river wm version to be at least {d}.", .{wm_version});
                }
                const wm_obj = registry.bind(ev.name, river.WindowManagerV1, wm_version) catch
                    fatal("Out of memory.", .{});
                globals.window_manager = wm_obj;

                wm_obj.setListener(?*anyopaque, Delta.listener, null);
            } else if (std.mem.orderZ(u8, river.XkbBindingsV1.interface.name, ev.interface) == .eq) {
                globals.xkb_bindings = registry.bind(
                    ev.name,
                    river.XkbBindingsV1,
                    xkb_bindings_version,
                ) catch fatal("Out of memory.", .{});
            }
        },
        else => {},
    }
}
