const std = @import("std");
const posix = std.posix;
const wm = &@import("Delta.zig").instance;
const log = std.log.scoped(.action);

pub fn spawn(argv: []const []const u8) void {
    std.debug.assert(argv.len > 0);

    var arena = std.heap.ArenaAllocator.init(wm.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const child_argv = a.allocSentinel(?[*:0]const u8, argv.len, null) catch {
        log.err("out of memory spawning {s}", .{argv[0]});
        return;
    };
    for (argv, 0..) |arg, i| {
        const dup = a.dupeZ(u8, arg) catch {
            log.err("out of memory spawning {s}", .{argv[0]});
            return;
        };
        child_argv[i] = dup.ptr;
    }

    const env_block = wm.child_env.createPosixBlock(a, .{}) catch {
        log.err("failed to build environment for {s}", .{argv[0]});
        return;
    };

    log.info("spawning {s}", .{argv[0]});

    const rc = posix.system.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| {
            log.err("fork failed spawning {s}: {s}", .{ argv[0], @tagName(err) });
            return;
        },
    }

    if (rc != 0) return; // parent

    _ = std.c.setsid();
    _ = posix.system.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null);

    const dfl: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &dfl, null);
    posix.execvpeZ(child_argv[0].?, child_argv.ptr, env_block.slice.ptr) catch {};
    posix.system.exit(127);
}
