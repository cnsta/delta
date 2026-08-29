const std = @import("std");

const posix = std.posix;
const linux = std.os.linux;

const Watcher = @This();

const log = std.log.scoped(.default);

fd: posix.fd_t,

name: []const u8,

const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE;

pub fn init(path: []const u8) ?Watcher {
    const dir = std.fs.path.dirname(path) orelse ".";
    const name = std.fs.path.basename(path);
    if (name.len == 0) return null;

    const fd = posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC) catch |err| {
        log.warn("cannot watch for config changes: {t}", .{err});
        return null;
    };

    _ = posix.inotify_add_watch(fd, dir, mask) catch |err| {
        log.warn("cannot watch {s}: {t}", .{ dir, err });
        posix.close(fd);
        return null;
    };

    return .{ .fd = fd, .name = name };
}

pub fn deinit(watcher: *Watcher) void {
    posix.close(watcher.fd);
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

            if (event.len > 0) {
                const raw = buffer[offset + @sizeOf(Event) ..][0..event.len];
                const name = std.mem.sliceTo(raw, 0);

                if (std.mem.eql(u8, name, watcher.name)) changed = true;
            }

            offset += @sizeOf(Event) + event.len;
        }
    }
}
