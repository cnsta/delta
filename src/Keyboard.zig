const std = @import("std");
const wayland = @import("wayland");
const xkb = @import("xkbcommon");

const wl = wayland.client.wl;
const river = wayland.client.river;
const linux = std.os.linux;
const posix = std.posix;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const syscall = @import("util/syscall.zig");
const Config = @import("Config.zig");
const InputDevice = @import("Libinput.zig").InputDevice;

const log = std.log.scoped(.keyboard);

const Keyboard = @This();

obj: *river.XkbKeyboardV1,
link: wl.list.Link,

input: ?*InputDevice = null,
want: ?*Keymap = null,

pub const Keymap = struct {
    obj: ?*river.XkbKeymapV1 = null,
    state: enum { pending, ready, failed } = .pending,
};

pub const State = struct {
    config: ?*river.XkbConfigV1 = null,
    keyboards: wl.list.Head(Keyboard, .link) = undefined,
    keymaps: std.ArrayList(?*Keymap) = .empty,
    touched: bool = false,
    names_hash: u64 = 0,
    repeat: [2]u32 = .{ 0, 0 },

    pub fn init(state: *State) void {
        state.* = .{
            .names_hash = fingerprint(wm.config.input.keyboard),
            .repeat = repeatOf(wm.config.input),
        };
        state.keyboards.init();
    }

    pub fn deinit(state: *State) void {
        while (state.keyboards.first()) |kb| kb.destroy();
        dropKeymaps();
        state.keymaps.deinit(wm.gpa);
    }
};

pub fn configListener(
    config: *river.XkbConfigV1,
    event: river.XkbConfigV1.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .xkb_keyboard => |args| {
            const kb = wm.gpa.create(Keyboard) catch fatal("Out of memory.", .{});
            kb.* = .{ .obj = args.id, .link = undefined };
            args.id.setListener(*Keyboard, listener, kb);
            wm.keyboard.keyboards.append(kb);
        },
        .finished => {
            config.destroy();
            wm.keyboard.config = null;
        },
    }
}

fn listener(_: *river.XkbKeyboardV1, event: river.XkbKeyboardV1.Event, kb: *Keyboard) void {
    switch (event) {
        .input_device => |args| {
            kb.input = if (args.device) |obj| @ptrCast(@alignCast(obj.getUserData())) else null;
            log.info("keyboard {s}", .{kb.name()});
            kb.apply();
        },
        .removed => kb.destroy(),
        else => {},
    }
}

pub fn destroy(kb: *Keyboard) void {
    if (!wm.shutting_down) kb.obj.destroy();
    kb.link.remove();
    wm.gpa.destroy(kb);
}

pub fn forgetDevice(device: *InputDevice) void {
    var it = wm.keyboard.keyboards.iterator(.forward);
    while (it.next()) |kb| {
        if (kb.input == device) kb.input = null;
    }
}

pub fn applyAll() void {
    const state = &wm.keyboard;

    const repeat = repeatOf(wm.config.input);
    if (!std.mem.eql(u32, &repeat, &state.repeat)) {
        state.repeat = repeat;
        var devices = wm.input_devices.iterator(.forward);
        while (devices.next()) |device| applyRepeat(device);
    }

    const hash = fingerprint(wm.config.input.keyboard);
    if (hash != state.names_hash) {
        state.names_hash = hash;
        dropKeymaps();
        var it = state.keyboards.iterator(.forward);
        while (it.next()) |kb| kb.apply();
    }
}

fn repeatOf(input: Config.Input) [2]u32 {
    return .{ input.repeat_rate, input.repeat_delay };
}

fn fingerprint(kb: Config.Keyboard) u64 {
    var h: std.hash.Wyhash = .init(0);
    hashNames(&h, kb.namesFor(null));
    for (kb.devices, 0..) |device, i| {
        h.update(device.name);
        h.update(&.{0});
        hashNames(&h, kb.namesFor(i));
    }
    return h.final();
}

fn hashNames(h: *std.hash.Wyhash, names: Config.Keyboard.Names) void {
    inline for (.{ "rules", "model", "layout", "variant", "options" }) |field| {
        if (@field(names, field)) |value| {
            h.update(&.{1});
            h.update(value);
        }
        h.update(&.{0});
    }
}

pub fn applyRepeat(device: *InputDevice) void {
    if (device.kind != .keyboard) return;
    const input = wm.config.input;
    device.obj.setRepeatInfo(@intCast(input.repeat_rate), @intCast(input.repeat_delay));
}

fn name(kb: *const Keyboard) []const u8 {
    const input = kb.input orelse return "(unnamed)";
    return input.name orelse "(unnamed)";
}

fn apply(kb: *Keyboard) void {
    const state = &wm.keyboard;
    const cfg = wm.config.input.keyboard;
    if (state.config == null) return;
    if (!cfg.configured() and !state.touched) return;

    const input_name = if (kb.input) |input| input.name else null;
    const source = cfg.pick(input_name);
    const keymap = keymapFor(source);

    kb.want = keymap;
    if (keymap.state == .ready) kb.setKeymap(keymap);
}

fn setKeymap(kb: *Keyboard, keymap: *Keymap) void {
    kb.obj.setKeymap(keymap.obj.?);
    kb.want = null;
    wm.keyboard.touched = true;
    log.info("keyboard {s}: keymap set", .{kb.name()});
}

fn keymapFor(source: Config.Keyboard.Source) *Keymap {
    const state = &wm.keyboard;
    const index = if (source) |i| i + 1 else 0;

    if (index >= state.keymaps.items.len) {
        state.keymaps.appendNTimes(wm.gpa, null, index + 1 - state.keymaps.items.len) catch
            fatal("Out of memory.", .{});
    }
    if (state.keymaps.items[index]) |existing| return existing;

    const keymap = wm.gpa.create(Keymap) catch fatal("Out of memory.", .{});
    keymap.* = .{};
    state.keymaps.items[index] = keymap;

    const names = wm.config.input.keyboard.namesFor(source);
    keymap.obj = createKeymap(names) catch |err| {
        log.err("cannot create keymap from {f}: {t}", .{ names, err });
        keymap.state = .failed;
        return keymap;
    };
    keymap.obj.?.setListener(*Keymap, keymapListener, keymap);
    log.info("keymap requested: {f}", .{names});
    return keymap;
}

fn keymapListener(_: *river.XkbKeymapV1, event: river.XkbKeymapV1.Event, keymap: *Keymap) void {
    switch (event) {
        .success => {
            keymap.state = .ready;
            var it = wm.keyboard.keyboards.iterator(.forward);
            while (it.next()) |kb| {
                if (kb.want == keymap) kb.setKeymap(keymap);
            }
        },
        .failure => |args| {
            keymap.state = .failed;
            log.err("River rejected the keymap: {s}", .{args.error_msg});
        },
    }
}

fn dropKeymaps() void {
    const state = &wm.keyboard;
    var it = state.keyboards.iterator(.forward);
    while (it.next()) |kb| kb.want = null;

    for (state.keymaps.items) |maybe| {
        const keymap = maybe orelse continue;
        if (keymap.obj) |obj| if (!wm.shutting_down) obj.destroy();
        wm.gpa.destroy(keymap);
    }
    state.keymaps.clearRetainingCapacity();
}

fn createKeymap(names: Config.Keyboard.Names) !*river.XkbKeymapV1 {
    const config = wm.keyboard.config orelse return error.NoXkbConfig;

    const context = xkb.Context.new(.no_flags) orelse return error.XkbContext;
    defer context.unref();
    const keymap = names.compile(context) orelse return error.CompileFailed;
    defer keymap.unref();
    const text = keymap.getAsString(.text_v1) orelse return error.SerializeFailed;
    defer std.c.free(text);

    const bytes = std.mem.span(text);
    const fd = try sealedFile("delta-keymap", bytes.ptr[0 .. bytes.len + 1]);
    defer _ = std.c.close(fd);

    return config.createKeymap(fd, .text_v1);
}

fn sealedFile(comptime label: []const u8, bytes: []const u8) !posix.fd_t {
    const fd = try posix.memfd_create(label, linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    errdefer _ = std.c.close(fd);

    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (syscall.failed(rc)) {
            if (syscall.errno(rc) == @backingInt(linux.E.INTR)) continue;
            return error.WriteFailed;
        }
        sent += rc;
    }

    const seals = linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_WRITE | linux.F.SEAL_SEAL;
    if (syscall.failed(linux.fcntl(fd, linux.F.ADD_SEALS, seals))) return error.SealFailed;
    return fd;
}
