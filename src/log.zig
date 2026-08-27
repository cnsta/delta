const std = @import("std");
const builtin = @import("builtin");

pub const Scope = enum {
    default,
    binding,
    action,
    layout,
    window,
    output,
    seat,
};

pub var level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    else => .info,
};

pub var scopes: std.EnumSet(Scope) = std.EnumSet(Scope).initFull();

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > @intFromEnum(level)) return;

    if (std.meta.stringToEnum(Scope, @tagName(scope))) |s| {
        if (!scopes.contains(s)) return;
    }

    std.log.defaultLog(message_level, scope, format, args);
}

pub fn parseScopes(spec: []const u8) !void {
    scopes = std.EnumSet(Scope).initEmpty();

    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;

        if (std.mem.eql(u8, raw, "all")) {
            scopes = std.EnumSet(Scope).initFull();
        } else if (raw[0] == '~') {
            scopes.remove(std.meta.stringToEnum(Scope, raw[1..]) orelse return error.UnknownScope);
        } else {
            scopes.insert(std.meta.stringToEnum(Scope, raw) orelse return error.UnknownScope);
        }
    }
}

pub fn parseLevel(spec: []const u8) !void {
    level = std.meta.stringToEnum(std.log.Level, spec) orelse {
        if (std.mem.eql(u8, spec, "error")) return setLevel(.err);
        if (std.mem.eql(u8, spec, "warning")) return setLevel(.warn);
        return error.UnknownLevel;
    };
}

fn setLevel(l: std.log.Level) void {
    level = l;
}
