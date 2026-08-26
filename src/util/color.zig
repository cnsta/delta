pub const Color = struct {
    r: u32,
    g: u32,
    b: u32,
    a: u32,
};

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{
        .r = widen(r),
        .g = widen(g),
        .b = widen(b),
        .a = widen(0xff),
    };
}

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
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0), widen(0x00));
    try std.testing.expectEqual(@as(u32, 0xffffffff), widen(0xff));
    try std.testing.expectEqual(@as(u32, 0x80808080), widen(0x80));
}
