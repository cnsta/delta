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
