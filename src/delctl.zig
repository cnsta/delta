const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

const protocol = @import("ipc/protocol.zig");
const syscall = @import("util/syscall.zig");

const version = @import("cli.zig").version;

const usage =
    \\usage: delctl [--json] <command>
    \\
    \\commands:
    \\  outputs      connected outputs and the workspace each is showing
    \\  workspaces   every workspace that exists
    \\  windows      every window delta knows about
    \\  layers       inferred bar/exclusion margins per output
    \\  focused      the focused window, if any
    \\  version      delta's version
    \\  watch        follow state changes until interrupted
    \\
    \\options:
    \\  --json       print delta's reply verbatim instead of a table
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

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
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

    const request = requestFor(cmd) orelse {
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

                try w.print(arena, "{s}{s}\n", .{
                    output.name,
                    if (output.focused) "  (focused)" else "",
                });

                if (output.description) |desc| {
                    try w.print(arena, "  {s}\n", .{desc});
                }

                if (output.mode) |mode| {
                    const refresh = mode.refresh;

                    try w.print(arena, "  mode       {d}x{d}@{d}.{d}{d}{d}Hz\n", .{
                        mode.width,
                        mode.height,
                        @divTrunc(refresh, 1000),
                        @divTrunc(@rem(refresh, 1000), 100),
                        @divTrunc(@rem(refresh, 100), 10),
                        @rem(refresh, 10),
                    });
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

                try w.print(arena, "  scale      {d}\n", .{output.scale});

                if (!std.mem.eql(u8, output.transform, "normal")) {
                    try w.print(arena, "  transform  {s}\n", .{output.transform});
                }

                try w.print(arena, "  workspace  {?d}\n", .{output.workspace});
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
            for (windows) |window| try renderWindow(arena, w, window);
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

fn renderWindow(
    arena: std.mem.Allocator,
    w: *std.ArrayList(u8),
    window: protocol.Window,
) !void {
    // identifier first, because it is what every other command takes as
    // an argument and the reason to run this at all is usually to find one.
    try w.print(arena, "{s}\n", .{window.id});
    try w.print(arena, "  app_id     {?s}\n", .{window.app_id});
    try w.print(arena, "  title      {?s}\n", .{window.title});
    try w.print(arena, "  workspace  {?d}\n", .{window.workspace});

    if (window.focused) try w.appendSlice(arena, "  focused\n");
    if (window.float) try w.appendSlice(arena, "  float\n");
    if (window.fullscreen) try w.appendSlice(arena, "  fullscreen\n");
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
