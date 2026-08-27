const std = @import("std");
const posix = std.posix;
const wm = &@import("Delta.zig").instance;
const log = std.log.scoped(.action);

const default_path = "/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin";

pub fn spawn(argv: []const []const u8) void {
    std.debug.assert(argv.len > 0);

    var arena = std.heap.ArenaAllocator.init(wm.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const child_argv = a.allocSentinel(?[*:0]const u8, argv.len, null) catch return oom(argv[0]);
    for (argv, 0..) |arg, i| {
        const dup = a.dupeZ(u8, arg) catch return oom(argv[0]);
        child_argv[i] = dup.ptr;
    }

    const env_block = wm.child_env.createPosixBlock(a, .{}) catch return oom(argv[0]);
    const candidates = resolve(a, argv[0]) catch return oom(argv[0]);
    if (candidates.len == 0) {
        log.err("cannot spawn {s}: PATH is empty", .{argv[0]});
        return;
    }

    log.info("spawning {s}", .{argv[0]});

    const rc = posix.system.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| {
            log.err("fork failed spawning {s}: {t}", .{ argv[0], err });
            return;
        },
    }

    if (rc != 0) return; // parent
    _ = std.c.setsid();
    var empty = posix.sigemptyset();
    _ = posix.system.sigprocmask(posix.SIG.SETMASK, &empty, null);
    const dfl: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = empty,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &dfl, null);

    for (candidates) |path| {
        _ = posix.system.execve(path, child_argv.ptr, env_block.slice.ptr);
    }

    posix.system.exit(127);
}

fn resolve(a: std.mem.Allocator, name: []const u8) ![]const [*:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const dup = try a.dupeZ(u8, name);
        const one = try a.alloc([*:0]const u8, 1);
        one[0] = dup.ptr;
        return one;
    }

    const path = wm.child_env.get("PATH") orelse default_path;
    var out: std.ArrayList([*:0]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;

        const joined = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
        try out.append(a, joined.ptr);
    }
    return out.items;
}

fn oom(name: []const u8) void {
    log.err("out of memory spawning {s}", .{name});
}
