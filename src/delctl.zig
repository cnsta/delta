const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

const protocol = @import("ipc/protocol.zig");
const Action = @import("input/action.zig").Action;
const syscall = @import("util/syscall.zig");

const version = @import("cli.zig").version;

const usage =
    \\usage: delctl [--json] <command>
    \\
    \\commands:
    \\  outputs       outputs, their modes and vrr, and each one's workspace
    \\  workspaces    every workspace that exists
    \\  windows       every window delta knows about
    \\  layers        inferred bar/exclusion margins per output
    \\  focused       the focused window, if any
    \\  version       delta's version
    \\  watch         follow state changes until interrupted
    \\  action <name> [args]
    \\                run a keybinding action, `delctl action` lists them
    \\
    \\options:
    \\  --json        print delta's reply verbatim instead of a table
    \\
    \\delctl finds delta through $DELTA_SOCKET, falling back to
    \\$XDG_RUNTIME_DIR/delta-$WAYLAND_DISPLAY.sock.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    var json = false;
    var command: ?[]const u8 = null;
    var action_args: []const []const u8 = &.{};

    for (args[1..], 1..) |arg, i| {
        if (command != null and std.mem.eql(u8, command.?, "action")) {
            // The rest belongs to the action, flags included, so that
            // `delctl action spawn foot -e htop` means what it says.
            action_args = args[i..];
            break;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try write(1, usage);
            return;
        } else if (command == null) {
            command = arg;
        } else {
            try write(2, "delctl: too many arguments\n");
            std.process.exit(2);
        }
    }

    const cmd = command orelse {
        try write(2, usage);
        std.process.exit(2);
    };

    const request = if (std.mem.eql(u8, cmd, "action"))
        try actionRequest(action_args)
    else
        requestFor(cmd) orelse {
            try write(2, "delctl: unknown command\n\n");
            try write(2, usage);
            std.process.exit(2);
        };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fd = try connect(arena, init.environ_map);
    defer _ = std.c.close(fd);

    const line = try std.json.Stringify.valueAlloc(arena, request, .{});
    try write(fd, line);
    try write(fd, "\n");

    if (std.mem.eql(u8, cmd, "watch")) return watch(arena, fd);

    const reply = try readLine(arena, fd);

    if (json) {
        try write(1, reply);
        try write(1, "\n");
        return;
    }

    try render(arena, reply);
}

fn requestFor(cmd: []const u8) ?protocol.Request {
    if (std.mem.eql(u8, cmd, "outputs")) return .outputs;
    if (std.mem.eql(u8, cmd, "workspaces")) return .workspaces;
    if (std.mem.eql(u8, cmd, "windows")) return .windows;
    if (std.mem.eql(u8, cmd, "layers")) return .layers;
    if (std.mem.eql(u8, cmd, "focused")) return .focused_window;
    if (std.mem.eql(u8, cmd, "version")) return .version;
    if (std.mem.eql(u8, cmd, "watch")) return .event_stream;
    return null;
}

fn actionRequest(args: []const []const u8) !protocol.Request {
    if (args.len == 0) {
        try write(1, "actions:\n" ++ Action.listing);
        std.process.exit(0);
    }

    const action = Action.fromArgs(args) catch |err| {
        try write(2, switch (err) {
            error.UnknownAction => "delctl: unknown action\n\n",
            error.MissingArgument => "delctl: missing argument\n\n",
            error.InvalidArgument => "delctl: invalid argument\n\n",
            error.TooManyArguments => "delctl: too many arguments\n\n",
        });
        try write(2, "actions:\n" ++ Action.listing);
        std.process.exit(2);
    };

    return .{ .action = action };
}

// -- connection ----------------------------------------------------------

fn connect(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !posix.fd_t {
    const path = try socketPath(arena, environ) orelse {
        try write(2, "delctl: cannot locate delta's socket; is delta running?\n");
        std.process.exit(1);
    };

    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);

    const fd_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (syscall.failed(fd_rc)) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(fd_rc);
    errdefer _ = std.c.close(fd);

    const addr_len: linux.socklen_t = @intCast(@sizeOf(linux.sa_family_t) + path.len + 1);

    if (syscall.failed(linux.connect(fd, @ptrCast(&addr), addr_len))) {
        try write(2, "delctl: cannot connect to delta; is it running?\n");
        std.process.exit(1);
    }

    return fd;
}

/// `$DELTA_SOCKET`, or the same path delta derives.
/// The fallback matters for anything delta did not spawn
fn socketPath(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !?[]const u8 {
    if (environ.get("DELTA_SOCKET")) |path| {
        if (path.len > 0) return path;
    }

    const dir = environ.get("XDG_RUNTIME_DIR") orelse return null;
    const display = environ.get("WAYLAND_DISPLAY") orelse return null;

    return try std.fmt.allocPrint(arena, "{s}/delta-{s}.sock", .{ dir, display });
}

fn readLine(arena: std.mem.Allocator, fd: posix.fd_t) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    while (true) {
        var byte: [1]u8 = undefined;
        const n = try posix.read(fd, &byte);
        if (n == 0) return error.ConnectionClosed;

        if (byte[0] == '\n') return buf.items;
        try buf.append(arena, byte[0]);
    }
}

fn watch(arena: std.mem.Allocator, fd: posix.fd_t) !void {
    // Handshake reply discarded. Watch is about what comes after it.
    _ = try readLine(arena, fd);

    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;

    while (true) {
        const n = try posix.read(fd, &chunk);
        if (n == 0) return;

        try buf.appendSlice(arena, chunk[0..n]);

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buf.items, start, '\n')) |end| {
            try write(1, buf.items[start..end]);
            try write(1, "\n");
            start = end + 1;
        }

        // Keeping only the remainder stops the arena growing for the life of
        // a watch that may run for days.
        const rest = buf.items.len - start;
        std.mem.copyForwards(u8, buf.items[0..rest], buf.items[start..]);
        buf.shrinkRetainingCapacity(rest);
    }
}

// -- output --------------------------------------------------------------

fn render(arena: std.mem.Allocator, reply_json: []const u8) !void {
    const parsed = std.json.parseFromSliceLeaky(
        protocol.Reply,
        arena,
        reply_json,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        var msg: std.ArrayList(u8) = .empty;
        try msg.print(arena, "delctl: could not parse delta's reply: {t}\n{s}\n", .{
            err, reply_json,
        });
        try write(2, msg.items);
        std.process.exit(1);
    };

    var out: std.ArrayList(u8) = .empty;
    const w = &out;

    switch (parsed) {
        .err => |message| {
            try w.appendSlice(arena, "error: ");
            try w.appendSlice(arena, message);
            try w.append(arena, '\n');
            try write(2, out.items);
            std.process.exit(1);
        },

        .ok => try w.appendSlice(arena, "ok\n"),

        .version => |v| {
            try w.appendSlice(arena, v);
            try w.append(arena, '\n');
        },

        .outputs => |list| {
            for (list, 0..) |output, i| {
                if (i > 0) try w.append(arena, '\n');
                try renderOutput(arena, w, output);
            }
        },

        .workspaces => |workspaces| {
            for (workspaces) |ws| {
                try w.print(arena, "{d}  {s}{s}{s}{s}\n", .{
                    ws.id,
                    ws.output orelse "-",
                    if (ws.active) "  active" else "",
                    if (ws.focused) "  focused" else "",
                    if (ws.populated) "" else "  empty",
                });
            }
        },

        .windows => |windows| {
            for (windows, 0..) |window, i| {
                if (i > 0) try w.append(arena, '\n');
                try renderWindow(arena, w, window);
            }
        },

        .focused_window => |window| {
            if (window) |win| {
                try renderWindow(arena, w, win);
            } else {
                try w.appendSlice(arena, "no focused window\n");
            }
        },

        .layers => |list| {
            for (list, 0..) |l, i| {
                if (i > 0) try w.append(arena, '\n');

                try w.print(arena, "{s}\n", .{l.output});
                try w.print(arena, "  top     {d}\n", .{l.top});
                try w.print(arena, "  bottom  {d}\n", .{l.bottom});
                try w.print(arena, "  left    {d}\n", .{l.left});
                try w.print(arena, "  right   {d}\n", .{l.right});
            }
        },
    }

    try write(1, out.items);
}

fn renderOutput(
    arena: std.mem.Allocator,
    w: *std.ArrayList(u8),
    output: protocol.OutputInfo,
) !void {
    try w.print(arena, "{s}{s}{s}\n", .{
        output.name,
        if (output.focused) "  (focused)" else "",
        if (output.enabled) "" else "  (disabled)",
    });

    if (output.description) |desc| try w.print(arena, "  {s}\n", .{desc});
    if (output.make) |make| try w.print(arena, "  make       {s}\n", .{make});
    if (output.model) |model| try w.print(arena, "  model      {s}\n", .{model});
    if (output.serial) |serial| try w.print(arena, "  serial     {s}\n", .{serial});
    if (output.physical) |p| try w.print(arena, "  physical   {d}x{d} mm\n", .{ p.width, p.height });

    if (output.enabled) {
        if (output.mode) |mode| {
            try w.print(arena, "  mode       {d}x{d}@", .{ mode.width, mode.height });
            try printRefresh(arena, w, mode.refresh);
            try w.appendSlice(arena, "Hz");
            if (isPreferred(output.modes, mode)) try w.appendSlice(arena, "  preferred");
            try w.append(arena, '\n');
        } else {
            try w.appendSlice(arena, "  mode       unknown\n");
        }

        try w.print(arena, "  logical    {d}x{d} at {d},{d}\n", .{
            output.width, output.height, output.x, output.y,
        });

        if (output.usable.width != output.width or
            output.usable.height != output.height)
        {
            try w.print(arena, "  usable     {d}x{d} at {d},{d}\n", .{
                output.usable.width,
                output.usable.height,
                output.usable.x,
                output.usable.y,
            });
        }

        if (output.fractional_scale) |scale| {
            try w.print(arena, "  scale      {d}\n", .{scale});
        } else {
            try w.print(arena, "  scale      {d}\n", .{output.scale});
        }

        if (!std.mem.eql(u8, output.transform, "normal")) {
            try w.print(arena, "  transform  {s}\n", .{output.transform});
        }

        if (output.adaptive_sync) |on| {
            try w.print(arena, "  vrr        {s}\n", .{if (on) "on" else "off"});
        }

        if (output.captured) |n| {
            if (n > 0) try w.print(arena, "  captured   {d} session(s)\n", .{n});
        }

        try w.print(arena, "  workspace  {?d}\n", .{output.workspace});
    }

    const groups = try groupModes(arena, output.modes);
    for (groups, 0..) |group, i| {
        try w.appendSlice(arena, if (i == 0) "  modes      " else "             ");
        try w.print(arena, "{d}x{d} ", .{ group.width, group.height });

        for (group.modes) |mode| {
            try w.append(arena, ' ');
            try printRefresh(arena, w, mode.refresh);
            if (mode.current) try w.append(arena, '*');
            if (mode.preferred) try w.append(arena, '+');
        }
        try w.append(arena, '\n');
    }
}

fn printRefresh(arena: std.mem.Allocator, w: *std.ArrayList(u8), refresh: i32) !void {
    const mhz: u32 = @intCast(@max(refresh, 0));
    try w.print(arena, "{d}.{d:0>3}", .{ mhz / 1000, mhz % 1000 });
}

fn isPreferred(modes: []const protocol.ModeInfo, mode: protocol.Mode) bool {
    for (modes) |m| {
        if (m.width == mode.width and m.height == mode.height and m.refresh == mode.refresh) {
            return m.preferred;
        }
    }
    return false;
}

const ModeGroup = struct {
    width: i32,
    height: i32,
    modes: []const protocol.ModeInfo,
};

fn groupModes(
    arena: std.mem.Allocator,
    modes: []const protocol.ModeInfo,
) ![]const ModeGroup {
    var groups: std.ArrayList(ModeGroup) = .empty;

    for (modes, 0..) |mode, i| {
        const seen = for (modes[0..i]) |earlier| {
            if (earlier.width == mode.width and earlier.height == mode.height) break true;
        } else false;
        if (seen) continue;

        var members: std.ArrayList(protocol.ModeInfo) = .empty;
        for (modes[i..]) |m| {
            if (m.width == mode.width and m.height == mode.height) try members.append(arena, m);
        }

        try groups.append(arena, .{
            .width = mode.width,
            .height = mode.height,
            .modes = members.items,
        });
    }

    return groups.items;
}

test "modes group by resolution in listed order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const groups = try groupModes(arena, &.{
        .{ .width = 2560, .height = 1440, .refresh = 239970, .preferred = true },
        .{ .width = 1920, .height = 1080, .refresh = 60000 },
        .{ .width = 2560, .height = 1440, .refresh = 143998, .current = true },
        .{ .width = 1920, .height = 1080, .refresh = 50000 },
    });

    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqual(@as(i32, 2560), groups[0].width);
    try std.testing.expectEqual(@as(usize, 2), groups[0].modes.len);
    try std.testing.expectEqual(@as(i32, 143998), groups[0].modes[1].refresh);
    try std.testing.expectEqual(@as(i32, 50000), groups[1].modes[1].refresh);
}

test "an output renders its modes and vrr state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try renderOutput(arena, &out, .{
        .name = "DP-3",
        .description = null,
        .x = 0,
        .y = 0,
        .width = 2560,
        .height = 1440,
        .usable = .{ .x = 0, .y = 0, .width = 2560, .height = 1440 },
        .mode = .{ .width = 2560, .height = 1440, .refresh = 143998 },
        .scale = 1,
        .transform = "normal",
        .workspace = 1,
        .focused = true,
        .fractional_scale = 1,
        .adaptive_sync = false,
        .modes = &.{
            .{ .width = 2560, .height = 1440, .refresh = 239970, .preferred = true },
            .{ .width = 2560, .height = 1440, .refresh = 143998, .current = true },
            .{ .width = 1920, .height = 1080, .refresh = 60000 },
        },
    });

    try std.testing.expectEqualStrings(
        \\DP-3  (focused)
        \\  mode       2560x1440@143.998Hz
        \\  logical    2560x1440 at 0,0
        \\  scale      1
        \\  vrr        off
        \\  workspace  1
        \\  modes      2560x1440  239.970+ 143.998*
        \\             1920x1080  60.000
        \\
    , out.items);
}

fn renderWindow(
    arena: std.mem.Allocator,
    w: *std.ArrayList(u8),
    window: protocol.WindowInfo,
) !void {
    // identifier first, because it is what every other command takes as
    // an argument and the reason to run this at all is usually to find one.
    try w.print(arena, "{s}\n", .{window.id});
    try w.print(arena, "  app_id     {?s}\n", .{window.app_id});
    try w.print(arena, "  title      {?s}\n", .{window.title});

    try w.print(arena, "  workspace  {?d}", .{window.workspace});
    if (window.output) |output| try w.print(arena, " on {s}", .{output});
    try w.append(arena, '\n');

    if (window.geometry) |g| {
        try w.print(arena, "  at         {d},{d}\n", .{ g.x, g.y });
        try w.print(arena, "  size       {d}x{d}", .{ g.width, g.height });

        if (window.size) |s| {
            if (s.width != g.width or s.height != g.height) {
                try w.print(arena, "  (client {d}x{d})", .{ s.width, s.height });
            }
        }
        try w.append(arena, '\n');
    } else if (window.size) |s| {
        try w.print(arena, "  size       {d}x{d}  (client)\n", .{ s.width, s.height });
    }

    if (window.min_size) |s| try w.print(arena, "  min        {d}x{d}\n", .{ s.width, s.height });
    if (window.max_size) |s| try w.print(arena, "  max        {d}x{d}\n", .{ s.width, s.height });

    if (window.pid) |pid| try w.print(arena, "  pid        {d}\n", .{pid});
    if (window.parent) |parent| try w.print(arena, "  parent     {s}\n", .{parent});
    if (window.decoration) |d| try w.print(arena, "  decoration {s}\n", .{d});
    if (window.captured) |n| {
        if (n > 0) try w.print(arena, "  captured   {d} session(s)\n", .{n});
    }

    var flags: std.ArrayList(u8) = .empty;
    inline for (.{
        .{ window.focused, "focused" },
        .{ window.float, "float" },
        .{ window.fullscreen, "fullscreen" },
        .{ window.dialog, "dialog" },
        .{ window.hidden, "hidden" },
    }) |flag| {
        if (flag[0]) try flags.print(arena, " {s}", .{flag[1]});
    }
    if (window.presentation) |p| {
        if (!std.mem.eql(u8, p, "vsync")) try flags.print(arena, " {s}", .{p});
    }
    if (flags.items.len > 0) try w.print(arena, "  flags     {s}\n", .{flags.items});
}

/// Write everything, retrying short writes.
fn write(fd: posix.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;

    while (sent < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + sent, bytes.len - sent);

        if (syscall.failed(rc)) {
            return switch (syscall.errno(rc)) {
                @intFromEnum(linux.E.INTR) => continue,
                @intFromEnum(linux.E.PIPE) => std.process.exit(0),
                else => error.WriteFailed,
            };
        }

        sent += rc;
    }
}
