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

    var act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.NOCLDWAIT,
    };
    posix.sigaction(posix.SIG.CHLD, &act, null);

    const signals = try posix.signalfd(-1, &mask, posix.SFD.CLOEXEC | posix.SFD.NONBLOCK);

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
    posix.close(loop.signals);
}

pub fn run(loop: *Loop) !void {
    while (wm.running) {
        while (!loop.display.prepareRead()) {
            if (loop.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }

        if (loop.display.flush() != .SUCCESS) {
            loop.display.cancelRead();
            return error.FlushFailed;
        }

        const n = posix.poll(&loop.fds, wm.pollTimeout()) catch |err| {
            loop.display.cancelRead();
            return err;
        };

        if (n > 0 and loop.fds[wayland_fd].revents & posix.POLL.IN != 0) {
            if (loop.display.readEvents() != .SUCCESS) return error.ReadFailed;
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

        switch (info.signo) {
            posix.SIG.INT, posix.SIG.TERM => {
                log.info("caught signal {d}, shutting down", .{info.signo});

                wm.obj.stop();
            },
            posix.SIG.HUP => log.info("caught SIGHUP (config reload is not implemented yet)", .{}),
            else => {},
        }
    }
}
