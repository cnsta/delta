const std = @import("std");
const wayland = @import("wayland");
const xkb = @import("xkbcommon");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("../Delta.zig").instance;

const Action = @import("action.zig").Action;
const Seat = @import("../Seat.zig");

const log = std.log.scoped(.binding);

const XkbBinding = @This();

obj: *river.XkbBindingV1,
seat: *Seat,
action: Action = .none,
link: wl.list.Link,

enabled: bool = false,

pub fn create(
    seat: *Seat,
    mods: river.SeatV1.Modifiers,
    keysym: xkb.Keysym,
    action: Action,
) void {
    const binding = wm.gpa.create(XkbBinding) catch fatal("Out of memory.", .{});
    const obj = wm.xkb_bindings.getXkbBinding(
        seat.obj,
        @intFromEnum(keysym),
        mods,
    ) catch fatal("Out of memory.", .{});

    binding.* = .{
        .obj = obj,
        .seat = seat,
        .action = action,
        .link = undefined,
    };
    seat.xkb_bindings.append(binding);

    binding.obj.setListener(*XkbBinding, listener, binding);

    const mods_bits: u32 = @bitCast(mods);
    log.info("xkb binding: keysym 0x{x} mods 0x{x} -> {s}", .{
        @intFromEnum(keysym), mods_bits, @tagName(action),
    });
}

pub fn setEnabled(binding: *XkbBinding, on: bool) void {
    if (binding.enabled == on) return;

    if (on) binding.obj.enable() else binding.obj.disable();
    binding.enabled = on;
    log.info("xkb binding {s}: {s}", .{ if (on) "enabled" else "disabled", @tagName(binding.action) });
}

pub fn destroy(binding: *XkbBinding) void {
    binding.obj.destroy();
    binding.link.remove();
    wm.gpa.destroy(binding);
}

fn listener(_: *river.XkbBindingV1, event: river.XkbBindingV1.Event, binding: *XkbBinding) void {
    switch (event) {
        .pressed => {
            binding.seat.pending_action = binding.action;
            binding.seat.beginRepeat(binding);
        },

        .released => binding.seat.endRepeat(binding),
        .stop_repeat => binding.seat.endRepeat(binding),
    }
}
