const std = @import("std");

const posix = std.posix;
const linux = std.os.linux;

const Watcher = @This();

const log = std.log.scoped(.default);

fd: posix.fd_t,

name: []const u8,

const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE;

pub fn init(path: []const u8) ?Watcher {
    const name = std.fs.path.basename(path);
    if (name.len == 0) return null;

    const dir = std.fs.path.dirname(path) orelse ".";
    const dir_z = posix.toPosixPath(dir) catch {
        log.warn("config path is too long to watch: {s}", .{path});
        return null;
    };

    const fd_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    const fd = checked(fd_rc) orelse {
        log.warn("cannot watch for config changes: errno {d}", .{-signed(fd_rc)});
        return null;
    };

    const wd_rc = linux.inotify_add_watch(@intCast(fd), &dir_z, mask);
    if (checked(wd_rc) == null) {
        log.warn("cannot watch {s}: errno {d}", .{ dir, -signed(wd_rc) });
        _ = std.c.close(@intCast(fd));
        return null;
    }

    return .{ .fd = @intCast(fd), .name = name };
}

pub fn deinit(watcher: *Watcher) void {
    _ = std.c.close(watcher.fd);
    watcher.* = undefined;
}

pub fn drain(watcher: *Watcher) bool {
    const Event = linux.inotify_event;

    var buffer: [4096]u8 align(@alignOf(Event)) = undefined;
    var changed = false;

    while (true) {
        const n = posix.read(watcher.fd, &buffer) catch |err| switch (err) {
            error.WouldBlock => return changed,
            else => {
                log.err("failed to read config watch: {t}", .{err});
                return changed;
            },
        };
        if (n == 0) return changed;

        var offset: usize = 0;
        while (offset + @sizeOf(Event) <= n) {
            const event: *const Event = @ptrCast(@alignCast(&buffer[offset]));

            if (event.getName()) |name| {
                if (std.mem.eql(u8, name, watcher.name)) changed = true;
            }

            offset += @sizeOf(Event) + event.len;
        }
    }
}

fn checked(rc: usize) ?usize {
    return if (signed(rc) < 0) null else rc;
}

fn signed(rc: usize) isize {
    return @bitCast(rc);
}
