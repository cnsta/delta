const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const river = wayland.client.river;
const fatal = std.process.fatal;

const wm = &@import("Delta.zig").instance;
const string = @import("util/string.zig");
const Config = @import("Config.zig");
const accel_curve = @import("util/accel_curve.zig");

const log = std.log.scoped(.libinput);

const Libinput = @This();

obj: *river.LibinputDeviceV1,
link: wl.list.Link,

input: ?*InputDevice = null,
touchpad: bool = false,
pointer: bool = false,

pub const InputDevice = struct {
    obj: *river.InputDeviceV1,
    link: wl.list.Link,
    name: ?[]const u8 = null,

    pub fn destroy(device: *InputDevice) void {
        var it = wm.libinput_devices.iterator(.forward);
        while (it.next()) |d| {
            if (d.input == device) d.input = null;
        }

        string.free(wm.gpa, &device.name);
        if (!wm.shutting_down) device.obj.destroy();
        device.link.remove();
        wm.gpa.destroy(device);
    }
};

pub fn inputManagerListener(
    manager: *river.InputManagerV1,
    event: river.InputManagerV1.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .input_device => |args| {
            const device = wm.gpa.create(InputDevice) catch fatal("Out of memory.", .{});
            device.* = .{ .obj = args.id, .link = undefined };
            args.id.setListener(*InputDevice, inputDeviceListener, device);
            wm.input_devices.append(device);
        },
        .finished => {
            manager.destroy();
            wm.input_manager = null;
        },
    }
}

fn inputDeviceListener(_: *river.InputDeviceV1, event: river.InputDeviceV1.Event, device: *InputDevice) void {
    switch (event) {
        .name => |args| _ = string.replace(wm.gpa, &device.name, args.name) catch fatal("Out of memory.", .{}),
        .removed => device.destroy(),
        .type, .done => {},
    }
}

pub fn configListener(
    config: *river.LibinputConfigV1,
    event: river.LibinputConfigV1.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .libinput_device => |args| {
            const device = wm.gpa.create(Libinput) catch fatal("Out of memory.", .{});
            device.* = .{ .obj = args.id, .link = undefined };
            args.id.setListener(*Libinput, listener, device);
            wm.libinput_devices.append(device);
        },
        .finished => {
            config.destroy();
            wm.libinput_config = null;
        },
    }
}

pub fn destroy(device: *Libinput) void {
    if (!wm.shutting_down) device.obj.destroy();
    device.link.remove();
    wm.gpa.destroy(device);
}

fn listener(_: *river.LibinputDeviceV1, event: river.LibinputDeviceV1.Event, device: *Libinput) void {
    switch (event) {
        .input_device => |args| device.input = if (args.device) |obj|
            @ptrCast(@alignCast(obj.getUserData()))
        else
            null,

        .tap_support => |args| if (args.finger_count > 0) {
            device.touchpad = true;
            log.info("touchpad {s}", .{device.name()});
            device.applyTouchpad(wm.config.input.touchpad);
        },

        .accel_profiles_support => |args| {
            const p = args.profiles;
            if (device.touchpad or !(p.flat or p.adaptive or p.custom)) return;
            device.pointer = true;
            log.info("pointer {s}", .{device.name()});
            device.applyPointer(wm.config.input.pointer);
        },

        .removed => device.destroy(),

        else => {},
    }
}

pub fn applyAll() void {
    var it = wm.libinput_devices.iterator(.forward);
    while (it.next()) |device| {
        if (device.touchpad) device.applyTouchpad(wm.config.input.touchpad);
        if (device.pointer) device.applyPointer(wm.config.input.pointer);
    }
}

fn name(device: *const Libinput) []const u8 {
    const input = device.input orelse return "(unnamed)";
    return input.name orelse "(unnamed)";
}

fn applyTouchpad(device: *Libinput, t: Config.Touchpad) void {
    const D = river.LibinputDeviceV1;
    const obj = device.obj;

    if (t.tap) |on| watch(obj.setTap(if (on) .enabled else .disabled), &settings.tap);
    if (t.tap_button_map) |map| watch(obj.setTapButtonMap(switch (map) {
        .lrm => D.TapButtonMap.lrm,
        .lmr => D.TapButtonMap.lmr,
    }), &settings.tap_button_map);
    if (t.drag) |on| watch(obj.setDrag(if (on) .enabled else .disabled), &settings.drag);
    if (t.drag_lock) |lock| watch(obj.setDragLock(switch (lock) {
        .disabled => D.DragLockState.disabled,
        .timeout => D.DragLockState.enabled_timeout,
        .sticky => D.DragLockState.enabled_sticky,
    }), &settings.drag_lock);
    if (t.three_finger_drag) |drag| watch(obj.setThreeFingerDrag(switch (drag) {
        .disabled => D.ThreeFingerDragState.disabled,
        .three_fingers => D.ThreeFingerDragState.enabled_3fg,
        .four_fingers => D.ThreeFingerDragState.enabled_4fg,
    }), &settings.three_finger_drag);

    if (t.natural_scroll) |on| watch(
        obj.setNaturalScroll(if (on) .enabled else .disabled),
        &settings.natural_scroll,
    );
    if (t.scroll_method) |method| watch(obj.setScrollMethod(switch (method) {
        .none => D.ScrollMethod.no_scroll,
        .two_finger => D.ScrollMethod.two_finger,
        .edge => D.ScrollMethod.edge,
    }), &settings.scroll_method);
    if (t.click_method) |method| watch(obj.setClickMethod(switch (method) {
        .none => D.ClickMethod.none,
        .button_areas => D.ClickMethod.button_areas,
        .clickfinger => D.ClickMethod.clickfinger,
    }), &settings.click_method);
    if (t.clickfinger_button_map) |map| watch(obj.setClickfingerButtonMap(switch (map) {
        .lrm => D.ClickfingerButtonMap.lrm,
        .lmr => D.ClickfingerButtonMap.lmr,
    }), &settings.clickfinger_button_map);

    if (t.dwt) |on| watch(obj.setDwt(if (on) .enabled else .disabled), &settings.dwt);
    if (t.dwtp) |on| watch(obj.setDwtp(if (on) .enabled else .disabled), &settings.dwtp);
    if (t.middle_emulation) |on| watch(
        obj.setMiddleEmulation(if (on) .enabled else .disabled),
        &settings.middle_emulation,
    );
    if (t.left_handed) |on| watch(
        obj.setLeftHanded(if (on) .enabled else .disabled),
        &settings.left_handed,
    );
    if (t.send_events) |mode| watch(obj.setSendEvents(switch (mode) {
        .enabled => D.SendEventsModes{},
        .disabled => D.SendEventsModes{ .disabled = true },
        .disabled_on_external_mouse => D.SendEventsModes{ .disabled_on_external_mouse = true },
    }), &settings.send_events);

    if (t.accel_profile) |profile| watch(obj.setAccelProfile(switch (profile) {
        .flat => D.AccelProfile.flat,
        .adaptive => D.AccelProfile.adaptive,
    }), &settings.accel_profile);
    if (t.accel_speed) |speed| {
        var value: [1]f64 = .{speed};
        var array = doubles(&value);
        watch(obj.setAccelSpeed(&array), &settings.accel_speed);
    }
}

fn applyPointer(device: *Libinput, p: Config.Pointer) void {
    const D = river.LibinputDeviceV1;
    const obj = device.obj;

    if (p.accel_curve) |curve| {
        const config = wm.libinput_config orelse return;
        const accel = config.createAccelConfig(.custom) catch fatal("Out of memory.", .{});
        defer accel.destroy();
        var points = accel_curve.sample(curve);
        var step: [1]f64 = .{points.step};
        var step_array = doubles(&step);
        var points_array = doubles(&points.values);
        watch(accel.setPoints(.motion, &step_array, &points_array), &settings.pointer_accel_curve);
        watch(obj.applyAccelConfig(accel), &settings.pointer_accel_curve);
    } else if (p.accel_profile) |profile| watch(obj.setAccelProfile(switch (profile) {
        .flat => D.AccelProfile.flat,
        .adaptive => D.AccelProfile.adaptive,
        .custom => unreachable, // Config requires accel_curve with it.
    }), &settings.pointer_accel_profile);
    if (p.accel_speed) |speed| {
        var value: [1]f64 = .{speed};
        var array = doubles(&value);
        watch(obj.setAccelSpeed(&array), &settings.pointer_accel_speed);
    }
}

fn doubles(values: []f64) wl.Array {
    const bytes: []u8 = @ptrCast(values);
    return .{ .size = bytes.len, .alloc = bytes.len, .data = bytes.ptr };
}

const Setting = struct { field: []const u8 };

const settings = struct {
    var tap: Setting = .{ .field = "touchpad.tap" };
    var tap_button_map: Setting = .{ .field = "touchpad.tap_button_map" };
    var drag: Setting = .{ .field = "touchpad.drag" };
    var drag_lock: Setting = .{ .field = "touchpad.drag_lock" };
    var three_finger_drag: Setting = .{ .field = "touchpad.three_finger_drag" };
    var natural_scroll: Setting = .{ .field = "touchpad.natural_scroll" };
    var scroll_method: Setting = .{ .field = "touchpad.scroll_method" };
    var click_method: Setting = .{ .field = "touchpad.click_method" };
    var clickfinger_button_map: Setting = .{ .field = "touchpad.clickfinger_button_map" };
    var dwt: Setting = .{ .field = "touchpad.dwt" };
    var dwtp: Setting = .{ .field = "touchpad.dwtp" };
    var middle_emulation: Setting = .{ .field = "touchpad.middle_emulation" };
    var left_handed: Setting = .{ .field = "touchpad.left_handed" };
    var send_events: Setting = .{ .field = "touchpad.send_events" };
    var accel_profile: Setting = .{ .field = "touchpad.accel_profile" };
    var accel_speed: Setting = .{ .field = "touchpad.accel_speed" };
    var pointer_accel_profile: Setting = .{ .field = "pointer.accel_profile" };
    var pointer_accel_speed: Setting = .{ .field = "pointer.accel_speed" };
    var pointer_accel_curve: Setting = .{ .field = "pointer.accel_curve" };
};

fn watch(result: anyerror!*river.LibinputResultV1, setting: *Setting) void {
    const obj = result catch fatal("Out of memory.", .{});
    obj.setListener(*Setting, resultListener, setting);
}

fn resultListener(result: *river.LibinputResultV1, event: river.LibinputResultV1.Event, setting: *Setting) void {
    switch (event) {
        .success => {},
        .unsupported => log.warn("input.{s} is not supported by the device", .{setting.field}),
        .invalid => log.warn("input.{s} was rejected as invalid", .{setting.field}),
    }
    result.destroy();
}
