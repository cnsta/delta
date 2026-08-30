const std = @import("std");

pub fn failed(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}

pub fn errno(rc: usize) isize {
    return -@as(isize, @bitCast(rc));
}

test "the boundary is the whole point" {
    try std.testing.expect(!failed(0));
    try std.testing.expect(!failed(5));

    try std.testing.expect(!failed(std.math.maxInt(isize)));

    const eaddrinuse: usize = @bitCast(@as(isize, -98));
    try std.testing.expect(failed(eaddrinuse));
    try std.testing.expectEqual(@as(isize, 98), errno(eaddrinuse));

    try std.testing.expect(failed(std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(isize, 1), errno(std.math.maxInt(usize)));
}
