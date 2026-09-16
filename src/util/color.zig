const std = @import("std");

pub const Color = struct {
    r: u32,
    g: u32,
    b: u32,
    a: u32,
};

/// Opaque color from the usual 8-bit components.
pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{
        .r = widen(r),
        .g = widen(g),
        .b = widen(b),
        .a = std.math.maxInt(u32),
    };
}

/// Opaque color from a packed 0xRRGGBB value, which is how a config writes one.
pub fn hex(value: u24) Color {
    return rgb(
        @truncate(value >> 16),
        @truncate(value >> 8),
        @truncate(value),
    );
}

/// Translucent color.
pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return .{
        .r = widen(premultiply(r, a)),
        .g = widen(premultiply(g, a)),
        .b = widen(premultiply(b, a)),
        .a = widen(a),
    };
}

fn widen(v: u8) u32 {
    return @as(u32, v) * 0x01010101;
}

/// Interpolates between two colors. `t` is clamped to [0, 1] first, so an
/// overshoot curve's out-of-range values can't over/underflow the mix.
pub fn lerp(from: Color, to: Color, t: f32) Color {
    const clamped = std.math.clamp(t, 0, 1);
    return .{
        .r = mix(from.r, to.r, clamped),
        .g = mix(from.g, to.g, clamped),
        .b = mix(from.b, to.b, clamped),
        .a = mix(from.a, to.a, clamped),
    };
}

pub fn eql(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

/// f64 intermediates so t=0/t=1 round-trip to bit-exact endpoints.
fn mix(a: u32, b: u32, t: f32) u32 {
    if (t <= 0) return a;
    if (t >= 1) return b;

    const fa: f64 = @floatFromInt(a);
    const fb: f64 = @floatFromInt(b);
    const v = fa + (fb - fa) * @as(f64, t);
    return @intFromFloat(@round(v));
}

fn premultiply(v: u8, a: u8) u8 {
    return @intCast((@as(u16, v) * @as(u16, a) + 127) / 255);
}

test widen {
    try std.testing.expectEqual(@as(u32, 0), widen(0x00));
    try std.testing.expectEqual(@as(u32, 0xffffffff), widen(0xff));
    try std.testing.expectEqual(@as(u32, 0x80808080), widen(0x80));
}

test premultiply {
    // Opaque leaves the component alone, transparent zeroes it.
    try std.testing.expectEqual(@as(u8, 0x7a), premultiply(0x7a, 0xff));
    try std.testing.expectEqual(@as(u8, 0), premultiply(0x7a, 0x00));

    // Half alpha halves the component, rounding half up.
    try std.testing.expectEqual(@as(u8, 0x80), premultiply(0xff, 0x80));
}

test rgb {
    const c = rgb(0x7a, 0xa2, 0xf7);
    try std.testing.expectEqual(@as(u32, 0x7a7a7a7a), c.r);
    try std.testing.expectEqual(@as(u32, 0xa2a2a2a2), c.g);
    try std.testing.expectEqual(@as(u32, 0xf7f7f7f7), c.b);
    try std.testing.expectEqual(@as(u32, 0xffffffff), c.a);
}

test rgba {
    try std.testing.expectEqual(rgb(0x7a, 0xa2, 0xf7), rgba(0x7a, 0xa2, 0xf7, 0xff));

    const clear = rgba(0xff, 0xff, 0xff, 0x00);
    try std.testing.expectEqual(@as(u32, 0), clear.r);
    try std.testing.expectEqual(@as(u32, 0), clear.a);
}

test hex {
    try std.testing.expectEqual(rgb(0x7a, 0xa2, 0xf7), hex(0x7aa2f7));
    try std.testing.expectEqual(rgb(0, 0, 0), hex(0x000000));
    try std.testing.expectEqual(rgb(0xff, 0xff, 0xff), hex(0xffffff));
}

test lerp {
    const a = hex(0x504945);
    const b = hex(0x4c7a5d);

    // Endpoints are bit-exact, not just close.
    try std.testing.expectEqual(a, lerp(a, b, 0));
    try std.testing.expectEqual(b, lerp(a, b, 1));

    const mid = lerp(a, b, 0.5);
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(a.r)) / 2.0 + @as(f64, @floatFromInt(b.r)) / 2.0,
        @as(f64, @floatFromInt(mid.r)),
        1.0,
    );

    // Overshoot curves can push t outside [0, 1]. Must clamp, not overflow.
    try std.testing.expectEqual(a, lerp(a, b, -0.5));
    try std.testing.expectEqual(b, lerp(a, b, 1.5));
}

test eql {
    const a = hex(0x504945);
    const b = hex(0x504945);
    const c = hex(0x4c7a5d);

    try std.testing.expect(eql(a, b));
    try std.testing.expect(!eql(a, c));
}
