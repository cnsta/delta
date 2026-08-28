const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn replace(gpa: Allocator, owned: *?[]const u8, incoming: ?[*:0]const u8) Allocator.Error!bool {
    const next: ?[]const u8 = if (incoming) |ptr| std.mem.sliceTo(ptr, 0) else null;

    if (owned.*) |current| {
        if (next) |value| {
            if (std.mem.eql(u8, current, value)) return false;
        }
    } else if (next == null) {
        return false;
    }

    const duped: ?[]const u8 = if (next) |value| try gpa.dupe(u8, value) else null;

    if (owned.*) |current| gpa.free(current);
    owned.* = duped;
    return true;
}

pub fn free(gpa: Allocator, owned: *?[]const u8) void {
    if (owned.*) |current| gpa.free(current);
    owned.* = null;
}

test "replace reports only real changes" {
    const gpa = std.testing.allocator;
    var owned: ?[]const u8 = null;
    defer free(gpa, &owned);

    try std.testing.expect(try replace(gpa, &owned, "firefox"));
    try std.testing.expectEqualStrings("firefox", owned.?);

    try std.testing.expect(!try replace(gpa, &owned, "firefox"));

    try std.testing.expect(try replace(gpa, &owned, "ghostty"));
    try std.testing.expectEqualStrings("ghostty", owned.?);

    try std.testing.expect(try replace(gpa, &owned, null));
    try std.testing.expect(owned == null);

    try std.testing.expect(!try replace(gpa, &owned, null));
}

test "replace does not leak across many updates" {
    const gpa = std.testing.allocator;
    var owned: ?[]const u8 = null;
    defer free(gpa, &owned);

    var buf: [32]u8 = undefined;
    for (0..100) |i| {
        const title = try std.fmt.bufPrintZ(&buf, "page {d} - browser", .{i});
        try std.testing.expect(try replace(gpa, &owned, title.ptr));
    }
}
