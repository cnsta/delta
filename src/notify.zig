const std = @import("std");

const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.default);

pub fn ready(socket_path: ?[]const u8) void {
    const path = socket_path orelse return;
    if (path.len == 0) return;

    var addr: linux.sockaddr.un = .{ .path = @splat(0) };

    if (path.len > addr.path.len) {
        log.warn("NOTIFY_SOCKET is too long to use: {s}", .{path});
        return;
    }
    @memcpy(addr.path[0..path.len], path);

    if (path[0] == '@') addr.path[0] = 0;

    const addr_len: linux.socklen_t = @intCast(@sizeOf(linux.sa_family_t) + path.len);

    const fd_rc = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (failed(fd_rc)) {
        log.warn("cannot open the notify socket: errno {d}", .{-signed(fd_rc)});
        return;
    }
    const fd: posix.fd_t = @intCast(fd_rc);
    defer _ = std.c.close(fd);

    const message = "READY=1";
    const sent = linux.sendto(fd, message.ptr, message.len, 0, @ptrCast(&addr), addr_len);
    if (failed(sent)) {
        log.warn("cannot signal readiness: errno {d}", .{-signed(sent)});
        return;
    }

    log.info("session ready", .{});
}

fn failed(rc: usize) bool {
    return signed(rc) < 0;
}

fn signed(rc: usize) isize {
    return @bitCast(rc);
}
