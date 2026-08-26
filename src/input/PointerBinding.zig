const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const fatal = std.process.fatal;

const wm = &@import("../Delta.zig").instance;

const Action = @import("action.zig").Action;
const Seat = @import("../Seat.zig");

const PointerBinding = @This();

obj: *river.PointerBindingV1,
seat: *Seat,
action: Action = .none,
link: wl.list.Link,

enabled: bool = false,

pub fn create(
    seat: *Seat,
    mods: river.SeatV1.Modifiers,
    button: u32,
    action: Action,
) void {
    const binding = wm.gpa.create(PointerBinding) catch fatal("Out of memory.", .{});
    const obj = seat.obj.getPointerBinding(button, mods) catch fatal("Out of memory.", .{});

    binding.* = .{
        .obj = obj,
        .seat = seat,
        .action = action,
        .link = undefined,
    };
    seat.pointer_bindings.append(binding);

    binding.obj.setListener(*PointerBinding, listener, binding);
}

pub fn setEnabled(binding: *PointerBinding, on: bool) void {
    if (binding.enabled == on) return;

    if (on) binding.obj.enable() else binding.obj.disable();
    binding.enabled = on;
}

pub fn destroy(binding: *PointerBinding) void {
    binding.obj.destroy();
    binding.link.remove();
    wm.gpa.destroy(binding);
}

fn listener(_: *river.PointerBindingV1, event: river.PointerBindingV1.Event, binding: *PointerBinding) void {
    switch (event) {
        .pressed => binding.seat.pending_action = binding.action,
        else => {},
    }
}
