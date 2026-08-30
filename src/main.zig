const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const cli = @import("cli.zig");
const Config = @import("Config.zig");
const Delta = @import("Delta.zig");
const Loop = @import("Loop.zig");

pub const std_options = @import("log.zig").std_options;

const wm_version = 4;
const xkb_bindings_version = 3;
const layer_shell_version = 1;

const Globals = struct {
    window_manager: ?*river.WindowManagerV1 = null,
    xkb_bindings: ?*river.XkbBindingsV1 = null,
    layer_shell: ?*river.LayerShellV1 = null,
};

const child_environment = [_][2][]const u8{
    .{ "XDG_CURRENT_DESKTOP", "river" },
    .{ "XDG_SESSION_TYPE", "wayland" },
    .{ "MOZ_ENABLE_WAYLAND", "1" },
    .{ "_JAVA_AWT_WM_NONREPARENTING", "1" },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);

    if (cli.parse(args[1..]).exit) |code| std.process.exit(code);

    std.log.info("delta {s} starting", .{cli.version});
    std.log.info("PATH={s}", .{init.environ_map.get("PATH") orelse "<unset>"});

    var child_env = try init.environ_map.clone(init.gpa);
    defer child_env.deinit();
    for (child_environment) |pair| try child_env.put(pair[0], pair[1]);
    _ = child_env.swapRemove("NOTIFY_SOCKET");

    const config_path = try Config.defaultPath(init.gpa, init.environ_map);
    defer if (config_path) |path| init.gpa.free(path);

    const loaded = try loadConfig(init.gpa, init.io, config_path);

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    var globals: Globals = .{};
    const registry = try display.getRegistry();
    registry.setListener(*Globals, registryListener, &globals);

    if (display.roundtrip() != .SUCCESS) fatal("Roundtrip failed.", .{});

    const notify_socket = init.environ_map.get("NOTIFY_SOCKET");

    const ipc_path = try socketPath(init.gpa, init.environ_map);
    defer if (ipc_path) |p| init.gpa.free(p);

    Delta.init(
        init.gpa,
        init.io,
        child_env,
        loaded,
        config_path,
        notify_socket,
        ipc_path,
        registry,
        globals.window_manager orelse
            fatal("river_window_manager_v1 not supported by the Wayland server.", .{}),
        globals.xkb_bindings orelse
            fatal("river_xkb_bindings_v1 not supported by the Wayland server.", .{}),
        globals.layer_shell,
    );

    if (globals.layer_shell == null) {
        std.log.warn("river_layer_shell_v1 unavailable; layer surfaces will be closed", .{});
    }

    var loop = try Loop.init(display);
    defer loop.deinit();

    if (ipc_path) |path| try child_env.put("DELTA_SOCKET", path);

    try loop.run();
    Delta.instance.deinit();

    std.log.info("delta exiting", .{});
}

fn socketPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    const dir = environ.get("XDG_RUNTIME_DIR") orelse {
        std.log.info("no XDG_RUNTIME_DIR, IPC disabled", .{});
        return null;
    };
    const display = environ.get("WAYLAND_DISPLAY") orelse "wayland-0";

    const path = try std.fmt.allocPrint(gpa, "{s}/delta-{s}.sock", .{ dir, display });
    return path;
}

fn loadConfig(gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Config.Loaded {
    const defaults: Config.Loaded = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .config = .{},
    };

    const real_path = path orelse {
        std.log.info("no config path; XDG_CONFIG_HOME and HOME are both unset", .{});
        return defaults;
    };

    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    if (try Config.load(gpa, io, real_path, &report)) |loaded| {
        var unused = defaults;
        unused.deinit();

        std.log.info("loaded {s}", .{real_path});
        return loaded;
    }

    if (report) |message| {
        std.log.err("{s}: {s}", .{ real_path, message });
        std.log.err("using built-in defaults", .{});
    } else {
        std.log.info("no config at {s}, using built-in defaults", .{real_path});
    }

    return defaults;
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
