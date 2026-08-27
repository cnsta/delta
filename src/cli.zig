const std = @import("std");

const log = @import("log.zig");

pub const version = "0.1.1";

pub const usage =
    \\usage: delta-wm [options]
    \\
    \\  -h, -help          Print this message and exit.
    \\  -version           Print the version and exit.
    \\  -log-level LEVEL   error, warning, info, or debug.
    \\  -log-scopes SPEC   Comma separated, `all` for everything, `~` to
    \\                     subtract. Example: -log-scopes all,~binding
    \\
;

pub const Result = struct {
    exit: ?u8 = null,
};

pub fn parse(args: []const [:0]const u8) Result {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (eql(arg, "-h") or eql(arg, "-help") or eql(arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return .{ .exit = 0 };
        } else if (eql(arg, "-version") or eql(arg, "--version")) {
            std.debug.print("{s}\n", .{version});
            return .{ .exit = 0 };
        } else if (eql(arg, "-log-level")) {
            i += 1;
            if (i >= args.len) return missing("-log-level");
            log.parseLevel(args[i]) catch return bad("log level", args[i]);
        } else if (eql(arg, "-log-scopes")) {
            i += 1;
            if (i >= args.len) return missing("-log-scopes");
            log.parseScopes(args[i]) catch return bad("log scope", args[i]);
        } else {
            std.debug.print("unknown option '{s}'\n{s}", .{ arg, usage });
            return .{ .exit = 1 };
        }
    }

    return .{};
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn missing(flag: []const u8) Result {
    std.debug.print("option '{s}' requires an argument\n{s}", .{ flag, usage });
    return .{ .exit = 1 };
}

fn bad(what: []const u8, value: []const u8) Result {
    std.debug.print("invalid {s} '{s}'\n{s}", .{ what, value, usage });
    return .{ .exit = 1 };
}
