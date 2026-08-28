const std = @import("std");
const wayland = @import("wayland");

const posix = std.posix;
const wl = wayland.client.wl;

const wm = &@import("Delta.zig").instance;

const Loop = @This();

const log = std.log.scoped(.default);

display: *wl.Display,

signals: posix.fd_t,

fds: [2]posix.pollfd,

const wayland_fd = 0;
const signal_fd = 1;

pub fn init(display: *wl.Display) !Loop {
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, posix.SIG.INT);
    posix.sigaddset(&mask, posix.SIG.TERM);
    posix.sigaddset(&mask, posix.SIG.HUP);
    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ignore, null);

    const no_zombies: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.NOCLDWAIT,
    };
    posix.sigaction(posix.SIG.CHLD, &no_zombies, null);

    const flags: u32 = @bitCast(posix.O{ .CLOEXEC = true, .NONBLOCK = true });
    const signals = try posix.signalfd(-1, &mask, flags);

    return .{
        .display = display,
        .signals = signals,
        .fds = .{
            .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = signals, .events = posix.POLL.IN, .revents = 0 },
        },
    };
}

pub fn deinit(loop: *Loop) void {
    _ = std.c.close(loop.signals);
}

pub fn run(loop: *Loop) !void {
    while (wm.running) {
        while (!loop.display.prepareRead()) {
            if (loop.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }

        if (loop.display.flush() != .SUCCESS) return loop.lost(.read_prepared);

        _ = posix.poll(&loop.fds, wm.pollTimeout()) catch |err| {
            loop.display.cancelRead();
            return err;
        };

        const revents = loop.fds[wayland_fd].revents;

        if (revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) return loop.lost(.read_prepared);

        if (revents & posix.POLL.IN != 0) {
            // readEvents releases the reader lock whether it succeeds or fails.
            if (loop.display.readEvents() != .SUCCESS) return loop.lost(.read_released);
        } else {
            loop.display.cancelRead();
        }

        if (loop.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;

        if (loop.fds[signal_fd].revents & posix.POLL.IN != 0) loop.readSignals();

        wm.tick();

        if (wm.dirty) {
            wm.dirty = false;
            wm.obj.manageDirty();
        }
    }
}

const ReadLock = enum { read_prepared, read_released };

fn lost(loop: *Loop, held: ReadLock) error{ConnectionLost}!void {
    if (held == .read_prepared) loop.display.cancelRead();

    if (wm.stopping()) {
        wm.running = false;
        return;
    }

    log.err("lost the Wayland connection", .{});
    return error.ConnectionLost;
}

fn readSignals(loop: *Loop) void {
    var info: std.os.linux.signalfd_siginfo = undefined;
    const bytes = std.mem.asBytes(&info);

    while (true) {
        const n = posix.read(loop.signals, bytes) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                log.err("failed to read signal: {s}", .{@errorName(err)});
                return;
            },
        };
        if (n != bytes.len) return;

        const sig: posix.SIG = @enumFromInt(info.signo);
        switch (sig) {
            .INT, .TERM => wm.requestStop(),
            .HUP => wm.reload(),
            else => {},
        }
    }
}
