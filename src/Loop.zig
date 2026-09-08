const std = @import("std");
const wayland = @import("wayland");

const posix = std.posix;
const wl = wayland.client.wl;

const wm = &@import("Delta.zig").instance;
const handler = @import("ipc/handler.zig");

const Watcher = @import("Watcher.zig");
const Server = @import("ipc/Server.zig");

const Loop = @This();

const log = std.log.scoped(.default);

display: *wl.Display,
signals: posix.fd_t,
watcher: ?Watcher,
fds: [4 + Server.max_clients]posix.pollfd,
last_manage: u64 = 0,
last_render: u64 = 0,
last_report: i64 = 0,

const wayland_fd = 0;
const signal_fd = 1;
const watch_fd = 2;
const ipc_fds = 3;

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

    const watcher = if (wm.config_path) |path| Watcher.init(path) else null;
    if (watcher != null) {
        log.info("watching {s} for changes", .{wm.config_path.?});
    }

    var loop: Loop = .{
        .display = display,
        .signals = signals,
        .watcher = watcher,
        .fds = @splat(.{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }),
    };

    loop.fds[wayland_fd].fd = display.getFd();
    loop.fds[signal_fd].fd = signals;
    loop.fds[watch_fd].fd = if (watcher) |w| w.fd else -1;

    return loop;
}

pub fn deinit(loop: *Loop) void {
    if (loop.watcher) |*w| w.deinit();
    _ = std.c.close(loop.signals);
}

pub fn run(loop: *Loop) !void {
    while (wm.running) {
        while (!loop.display.prepareRead()) {
            if (loop.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }

        if (loop.display.flush() != .SUCCESS) return loop.lost(.read_prepared);
        if (wm.server) |*server| server.fill(loop.fds[ipc_fds..]);

        _ = posix.poll(&loop.fds, wm.pollTimeout()) catch |err| {
            loop.display.cancelRead();
            return err;
        };

        wm.tickClock();

        const report_now = wm.millis();
        if (report_now - loop.last_report >= 1000) {
            log.debug("{d} manage/s, {d} render/s", .{
                wm.manage_count - loop.last_manage,
                wm.render_count - loop.last_render,
            });

            loop.last_manage = wm.manage_count;
            loop.last_render = wm.render_count;
            loop.last_report = report_now;
        }

        const revents = loop.fds[wayland_fd].revents;

        if (revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) return loop.lost(.read_prepared);
        if (revents & posix.POLL.IN != 0) {
            if (loop.display.readEvents() != .SUCCESS) return loop.lost(.read_released);
        } else {
            loop.display.cancelRead();
        }

        if (loop.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        if (loop.fds[signal_fd].revents & posix.POLL.IN != 0) loop.readSignals();
        if (loop.fds[watch_fd].revents & posix.POLL.IN != 0) {
            if (loop.watcher) |*w| {
                if (w.drain()) wm.scheduleReload();
            }
        }

        if (wm.server) |*server| server.dispatch(loop.fds[ipc_fds..], handler.handle);
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
