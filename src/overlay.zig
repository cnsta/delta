const std = @import("std");
const wayland = @import("wayland");

const river = wayland.client.river;
const wl = wayland.client.wl;
const wp = wayland.client.wp;

const wm = &@import("Delta.zig").instance;
const geom = @import("util/geom.zig");

const Window = @import("Window.zig");

const Overlay = @This();

const log = std.log.scoped(.window);

surface: *wl.Surface,
viewport: *wp.Viewport,
decoration: *river.DecorationV1,

buffer: ?*wl.Buffer = null,

applied: struct {
    offset: ?geom.Point = null,
    size: geom.Size = geom.Size.zero,
    color: Color = .{},
} = .{},

pub const Color = struct {
    r: u32 = 0,
    g: u32 = 0,
    b: u32 = 0,
    a: u32 = 0,

    pub fn rgba(hex: u24, alpha: f32) Color {
        const a = std.math.clamp(alpha, 0, 1);

        const r: f32 = @floatFromInt((hex >> 16) & 0xff);
        const g: f32 = @floatFromInt((hex >> 8) & 0xff);
        const b: f32 = @floatFromInt(hex & 0xff);

        const scale = a / 255.0;

        return .{
            .r = component(r * scale),
            .g = component(g * scale),
            .b = component(b * scale),
            .a = component(a),
        };
    }

    pub fn eql(x: Color, y: Color) bool {
        return x.r == y.r and x.g == y.g and x.b == y.b and x.a == y.a;
    }

    fn component(value: f32) u32 {
        const clamped = std.math.clamp(value, 0, 1);
        return @intFromFloat(@as(f64, clamped) * @as(f64, std.math.maxInt(u32)));
    }
};

pub fn create(window: *Window) ?Overlay {
    const compositor = wm.compositor orelse return null;
    const viewporter = wm.viewporter orelse return null;

    const surface = compositor.createSurface() catch {
        log.err("cannot create an overlay surface", .{});
        return null;
    };

    const viewport = viewporter.getViewport(surface) catch {
        log.err("cannot create an overlay viewport", .{});
        surface.destroy();
        return null;
    };

    const decoration = window.obj.getDecorationAbove(surface) catch {
        log.err("cannot create a decoration", .{});
        viewport.destroy();
        surface.destroy();
        return null;
    };

    const empty = compositor.createRegion() catch {
        log.err("cannot create an empty region", .{});
        decoration.destroy();
        viewport.destroy();
        surface.destroy();
        return null;
    };
    defer empty.destroy();

    surface.setInputRegion(empty);

    return .{
        .surface = surface,
        .viewport = viewport,
        .decoration = decoration,
    };
}

pub fn destroy(overlay: *Overlay) void {
    if (overlay.buffer) |buffer| buffer.destroy();

    overlay.decoration.destroy();
    overlay.viewport.destroy();
    overlay.surface.destroy();

    overlay.* = undefined;
}

pub fn update(overlay: *Overlay, offset: geom.Point, size: geom.Size, color: Color) void {
    const offset_changed = overlay.applied.offset == null or !offset.eql(overlay.applied.offset.?);
    if (offset_changed) {
        overlay.decoration.setOffset(offset.x, offset.y);
        overlay.applied.offset = offset;
    }

    if (!offset_changed and size.eql(overlay.applied.size) and color.eql(overlay.applied.color)) return;

    const manager = wm.single_pixel orelse return;

    if (size.width <= 0 or size.height <= 0) {
        overlay.surface.attach(null, 0, 0);
        overlay.decoration.syncNextCommit();
        overlay.surface.commit();

        if (overlay.buffer) |old| old.destroy();
        overlay.buffer = null;

        overlay.applied.size = geom.Size.zero;
        overlay.applied.color = color;
        return;
    }

    const buffer = manager.createU32RgbaBuffer(color.r, color.g, color.b, color.a) catch {
        log.err("cannot create a single-pixel buffer", .{});
        return;
    };

    overlay.viewport.setSource(
        wl.Fixed.fromInt(0),
        wl.Fixed.fromInt(0),
        wl.Fixed.fromInt(1),
        wl.Fixed.fromInt(1),
    );
    overlay.viewport.setDestination(size.width, size.height);

    overlay.surface.attach(buffer, 0, 0);
    overlay.surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    overlay.decoration.syncNextCommit();
    overlay.surface.commit();

    if (overlay.buffer) |old| old.destroy();
    overlay.buffer = buffer;

    overlay.applied.size = size;
    overlay.applied.color = color;
}
