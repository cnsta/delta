const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

const syscall = @import("../util/syscall.zig");

const Server = @This();

const log = std.log.scoped(.ipc);

pub const max_clients = 8;
const out_capacity = 64 * 1024;
const in_capacity = 4 * 1024;

fd: posix.fd_t,

path: [max_path]u8,
path_len: usize,

clients: [max_clients]Client = @splat(.{}),

const max_path = 108;

const Client = struct {
    fd: posix.fd_t = -1,

    streaming: bool = false,

    in: [in_capacity]u8 = undefined,
    in_len: usize = 0,

    out: [out_capacity]u8 = undefined,
    out_len: usize = 0,
};

pub fn init(path: []const u8) ?Server {
    if (path.len >= max_path) {
        log.warn("socket path is too long: {s}", .{path});
        return null;
    }

    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);

    _ = linux.unlink(@ptrCast(&addr.path));

    const fd_rc = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
        0,
    );
    if (syscall.failed(fd_rc)) {
        log.warn("cannot open the IPC socket: errno {d}", .{syscall.errno(fd_rc)});
        return null;
    }
    const fd: posix.fd_t = @intCast(fd_rc);

    const addr_len: linux.socklen_t = @intCast(@sizeOf(linux.sa_family_t) + path.len + 1);

    const bind_rc = linux.bind(fd, @ptrCast(&addr), addr_len);
    if (syscall.failed(bind_rc)) {
        log.warn("cannot bind {s}: errno {d}", .{ path, syscall.errno(bind_rc) });
        _ = std.c.close(fd);
        return null;
    }

    const listen_rc = linux.listen(fd, max_clients);
    if (syscall.failed(listen_rc)) {
        log.warn("cannot listen on {s}: errno {d}", .{ path, syscall.errno(listen_rc) });
        _ = std.c.close(fd);
        return null;
    }

    var server: Server = .{ .fd = fd, .path = @splat(0), .path_len = path.len };
    @memcpy(server.path[0..path.len], path);

    log.info("listening on {s}", .{path});
    return server;
}

pub fn deinit(server: *Server) void {
    for (&server.clients) |*client| server.drop(client);

    _ = std.c.close(server.fd);

    var path_z: [max_path]u8 = @splat(0);
    @memcpy(path_z[0..server.path_len], server.path[0..server.path_len]);
    _ = linux.unlink(@ptrCast(&path_z));

    server.* = undefined;
}

pub fn fill(server: *const Server, fds: []posix.pollfd) void {
    std.debug.assert(fds.len == 1 + max_clients);

    fds[0] = .{ .fd = server.fd, .events = posix.POLL.IN, .revents = 0 };

    for (server.clients, fds[1..]) |client, *entry| {
        entry.* = .{
            .fd = client.fd,
            .events = if (client.out_len > 0)
                posix.POLL.IN | posix.POLL.OUT
            else
                posix.POLL.IN,
            .revents = 0,
        };
    }
}

pub fn dispatch(server: *Server, fds: []const posix.pollfd, handler: Handler) void {
    std.debug.assert(fds.len == 1 + max_clients);

    if (fds[0].revents & posix.POLL.IN != 0) server.accept();

    for (&server.clients, fds[1..]) |*client, entry| {
        if (client.fd < 0) continue;

        if (entry.revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            server.drop(client);
            continue;
        }

        if (entry.revents & posix.POLL.OUT != 0) server.flush(client);
        if (client.fd < 0) continue;

        if (entry.revents & posix.POLL.IN != 0) server.read(client, handler);
    }
}

pub const Handler = *const fn (request: []const u8, streaming: *bool) ?[]const u8;

fn accept(server: *Server) void {
    while (true) {
        const rc = linux.accept4(server.fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);

        if (syscall.failed(rc)) {
            const err = syscall.errno(rc);
            if (err != @intFromEnum(linux.E.AGAIN) and err != @intFromEnum(linux.E.INTR)) {
                log.err("accept failed: errno {d}", .{err});
            }
            return;
        }

        const fd: posix.fd_t = @intCast(rc);

        const slot = server.free() orelse {
            log.warn("refusing an IPC client, {d} already connected", .{max_clients});
            _ = std.c.close(fd);
            continue;
        };

        slot.* = .{ .fd = fd };
    }
}

fn free(server: *Server) ?*Client {
    for (&server.clients) |*client| {
        if (client.fd < 0) return client;
    }
    return null;
}

fn drop(server: *Server, client: *Client) void {
    _ = server;
    if (client.fd < 0) return;

    _ = std.c.close(client.fd);
    client.* = .{};
}

fn read(server: *Server, client: *Client, handler: Handler) void {
    if (client.streaming) return;

    const room = client.in[client.in_len..];
    if (room.len == 0) {
        log.warn("dropping an IPC client: request line exceeded {d} bytes", .{in_capacity});
        server.drop(client);
        return;
    }

    const n = posix.read(client.fd, room) catch |err| switch (err) {
        error.WouldBlock => return,
        else => {
            server.drop(client);
            return;
        },
    };
    if (n == 0) {
        server.drop(client);
        return;
    }
    client.in_len += n;

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, client.in[0..client.in_len], start, '\n')) |end| {
        const line = client.in[start..end];
        start = end + 1;

        if (handler(line, &client.streaming)) |reply| {
            server.write(client, reply);
            server.write(client, "\n");
        }

        if (client.fd < 0) return;
    }

    const rest = client.in_len - start;
    std.mem.copyForwards(u8, client.in[0..rest], client.in[start..client.in_len]);
    client.in_len = rest;
}

fn write(server: *Server, client: *Client, bytes: []const u8) void {
    if (client.out_len == 0) {
        const n = writeSome(client.fd, bytes) orelse {
            server.drop(client);
            return;
        };
        if (n == bytes.len) return;

        server.buffer(client, bytes[n..]);
        return;
    }

    server.buffer(client, bytes);
}

fn buffer(server: *Server, client: *Client, bytes: []const u8) void {
    if (client.out_len + bytes.len > out_capacity) {
        log.warn("dropping an IPC client: {d} bytes behind", .{client.out_len});
        server.drop(client);
        return;
    }

    @memcpy(client.out[client.out_len..][0..bytes.len], bytes);
    client.out_len += bytes.len;
}

fn writeSome(fd: posix.fd_t, bytes: []const u8) ?usize {
    const rc = linux.write(fd, bytes.ptr, bytes.len);
    if (!syscall.failed(rc)) return rc;

    return switch (syscall.errno(rc)) {
        @intFromEnum(linux.E.AGAIN), @intFromEnum(linux.E.INTR) => 0,
        else => null,
    };
}

fn flush(server: *Server, client: *Client) void {
    const n = writeSome(client.fd, client.out[0..client.out_len]) orelse {
        server.drop(client);
        return;
    };
    if (n == 0) return;

    const rest = client.out_len - n;
    std.mem.copyForwards(u8, client.out[0..rest], client.out[n..client.out_len]);
    client.out_len = rest;
}

pub fn publish(server: *Server, line: []const u8) void {
    for (&server.clients) |*client| {
        if (client.fd < 0 or !client.streaming) continue;

        server.write(client, line);
        if (client.fd < 0) continue;
        server.write(client, "\n");
    }
}

pub fn hasStreamingClients(server: *const Server) bool {
    for (server.clients) |client| {
        if (client.fd >= 0 and client.streaming) return true;
    }
    return false;
}

pub fn publishRaw(server: *Server, bytes: []const u8) void {
    for (&server.clients) |*client| {
        if (client.fd < 0 or !client.streaming) continue;
        server.write(client, bytes);
    }
}
