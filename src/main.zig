const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const Delta = @import("Delta.zig");

const wm_version = 4;
const xkb_bindings_version = 3;
const layer_shell_version = 1;

const Globals = struct {
    window_manager: ?*river.WindowManagerV1 = null,
    xkb_bindings: ?*river.XkbBindingsV1 = null,
    layer_shell: ?*river.LayerShellV1 = null,
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
        globals.layer_shell,
    );

    if (globals.layer_shell == null) {
        std.log.warn("river_layer_shell_v1 unavailable; layer surfaces will be closed", .{});
    }

    while (true) {
        if (display.dispatch() != .SUCCESS) fatal("Dispatch failed.", .{});
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |ev| {
            if (std.mem.orderZ(u8, river.WindowManagerV1.interface.name, ev.interface) == .eq) {
                std.log.info("river_window_manager_v1 advertised v{d}, binding v{d}", .{
                    ev.version, wm_version,
                });
                if (ev.version < wm_version) {
                    fatal("Expected river wm version to be at least {d}.", .{wm_version});
                }
                const wm_obj = registry.bind(ev.name, river.WindowManagerV1, wm_version) catch
                    fatal("Out of memory.", .{});
                globals.window_manager = wm_obj;

                wm_obj.setListener(?*anyopaque, Delta.listener, null);
            } else if (std.mem.orderZ(u8, river.LayerShellV1.interface.name, ev.interface) == .eq) {
                std.log.info("river_layer_shell_v1 advertised v{d}, binding v{d}", .{
                    ev.version, layer_shell_version,
                });
                if (ev.version >= layer_shell_version) {
                    globals.layer_shell = registry.bind(
                        ev.name,
                        river.LayerShellV1,
                        layer_shell_version,
                    ) catch fatal("Out of memory.", .{});
                }
            } else if (std.mem.orderZ(u8, river.XkbBindingsV1.interface.name, ev.interface) == .eq) {
                std.log.info("river_xkb_bindings_v1 advertised v{d}, binding v{d}", .{
                    ev.version, xkb_bindings_version,
                });
                if (ev.version < xkb_bindings_version) {
                    fatal("Expected river_xkb_bindings_v1 to be at least v{d}.", .{xkb_bindings_version});
                }
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
