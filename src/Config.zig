const std = @import("std");

const Allocator = std.mem.Allocator;
const zon = std.zon;
const xkb = @import("xkbcommon");
const glob = @import("util/glob.zig");
const Io = std.Io;
const Action = @import("input/action.zig").Action;

const Config = @This();

gaps: Gaps = .{},
border: Border = .{},
input: Input = .{},
layout: Layout = .{},

bindings: ?[]const Binding = null,
on_error: ?[]const []const u8 = null,
pointer_bindings: ?[]const PointerBinding = null,
window_rules: []const WindowRule = &.{},

pub const Gaps = struct {
    between: i32 = 8,
    edge: i32 = 8,
};

pub const Border = struct {
    width: i32 = 2,
    focused: u24 = 0x4c7a5d,
    inactive: u24 = 0x504945,
};

pub const Input = struct {
    repeat_delay_ms: u32 = 400,
    repeat_rate_ms: u32 = 40,

    focus_follows_pointer: bool = true,
    focus_new_windows: bool = true,
    follow_sent_windows: bool = false,

    cursor: Cursor = .{},
    drag_threshold: i32 = 10,
};

pub const Cursor = struct {
    warp: Warp = .focus,

    pub const Warp = enum {
        none,
        focus,
        spawn,
    };
};

pub const Layout = struct {
    split_bias: f32 = 1.0,

    resize_step: i32 = 32,
};

pub const Modifier = enum { shift, ctrl, alt, super, mod3, mod5 };

pub const Binding = struct {
    mods: []const Modifier = &.{},
    keys: []const [:0]const u8,

    action: Action,
};

pub fn keysym(name: [:0]const u8) ?xkb.Keysym {
    const sym = xkb.Keysym.fromName(name, .no_flags);
    return if (sym == .NoSymbol) null else sym;
}

pub const PointerBinding = struct {
    mods: []const Modifier = &.{},

    button: Button,

    action: Action,

    pub const Button = enum { left, right, middle, side, extra };
};

pub const WindowRule = struct {
    matches: []const Match = &.{},

    excludes: []const Match = &.{},
    open_floating: ?bool = null,
    open_fullscreen: ?bool = null,
    open_workspace: ?u32 = null,
    open_focused: ?bool = null,
    open_warp: ?bool = null,
};

pub const Match = struct {
    app_id: ?[]const u8 = null,
    title: ?[]const u8 = null,

    dialog: ?bool = null,
};

pub const Candidate = struct {
    app_id: ?[]const u8,
    title: ?[]const u8,
    dialog: bool,
};

pub const Resolved = struct {
    floating: ?bool = null,
    fullscreen: ?bool = null,
    workspace: ?u32 = null,
    focused: ?bool = null,
    warp: ?bool = null,
};

pub fn resolve(config: *const Config, candidate: Candidate) Resolved {
    var result: Resolved = .{};

    for (config.window_rules) |rule| {
        if (!applies(rule, candidate)) continue;

        if (rule.open_floating) |v| result.floating = v;
        if (rule.open_fullscreen) |v| result.fullscreen = v;
        if (rule.open_workspace) |v| result.workspace = v;
        if (rule.open_focused) |v| result.focused = v;
        if (rule.open_warp) |v| result.warp = v;
    }

    return result;
}

fn applies(rule: WindowRule, candidate: Candidate) bool {
    if (rule.matches.len > 0) {
        var any = false;
        for (rule.matches) |m| {
            if (test_(m, candidate)) {
                any = true;
                break;
            }
        }
        if (!any) return false;
    }

    for (rule.excludes) |m| {
        if (test_(m, candidate)) return false;
    }

    return true;
}

fn test_(m: Match, candidate: Candidate) bool {
    if (m.app_id) |pattern| {
        const value = candidate.app_id orelse return false;
        if (!glob.match(pattern, value)) return false;
    }

    if (m.title) |pattern| {
        const value = candidate.title orelse return false;
        if (!glob.match(pattern, value)) return false;
    }

    if (m.dialog) |want| {
        if (candidate.dialog != want) return false;
    }

    return true;
}

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,

    pub fn deinit(loaded: *Loaded) void {
        loaded.arena.deinit();
        loaded.* = undefined;
    }
};

pub fn parse(gpa: Allocator, source: [:0]const u8, report: *?[]const u8) error{OutOfMemory}!?Loaded {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var diag: zon.parse.Diagnostics = .{};

    const config = zon.parse.fromSliceAlloc(Config, arena.allocator(), source, &diag, .{
        .ignore_unknown_fields = false,

        .free_on_error = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            report.* = try std.fmt.allocPrint(gpa, "{f}", .{diag});
            arena.deinit();
            return null;
        },
    };

    if (try validate(gpa, config, report)) {
        arena.deinit();
        return null;
    }

    return .{ .arena = arena, .config = config };
}

fn validate(gpa: Allocator, config: Config, report: *?[]const u8) error{OutOfMemory}!bool {
    if (@rem(config.gaps.between, 2) != 0) {
        report.* = try std.fmt.allocPrint(
            gpa,
            "gaps.between must be even so it can be split across two edges, found {d}",
            .{config.gaps.between},
        );
        return true;
    }

    if (config.gaps.between < 0 or config.gaps.edge < 0 or config.border.width < 0) {
        report.* = try std.fmt.allocPrint(gpa, "gaps and border width must not be negative", .{});
        return true;
    }

    if (config.layout.split_bias <= 0 or !std.math.isFinite(config.layout.split_bias)) {
        report.* = try std.fmt.allocPrint(
            gpa,
            "layout.split_bias must be a positive, finite number, found {d}",
            .{config.layout.split_bias},
        );
        return true;
    }

    if (config.bindings) |bindings| {
        for (bindings) |binding| {
            if (binding.keys.len == 0) {
                report.* = try std.fmt.allocPrint(gpa, "a binding needs at least one key", .{});
                return true;
            }

            for (binding.keys) |name| {
                if (keysym(name) != null) continue;

                report.* = try std.fmt.allocPrint(
                    gpa,
                    "unknown key name '{s}' -- these are xkb keysym names, case " ++
                        "sensitive, and name the unshifted symbol: \"Return\", " ++
                        "\"space\", \"plus\", \"F1\"",
                    .{name},
                );
                return true;
            }
        }
    }
    for (config.window_rules) |rule| {
        if (rule.open_workspace) |id| {
            if (id < 1 or id > 9) {
                report.* = try std.fmt.allocPrint(
                    gpa,
                    "open_workspace must be between 1 and 9, found {d}",
                    .{id},
                );
                return true;
            }
        }
    }
    return false;
}

const max_bytes = 1 << 20;

pub fn load(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    report: *?[]const u8,
) error{OutOfMemory}!?Loaded {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            report.* = try std.fmt.allocPrint(gpa, "cannot open {s}: {t}", .{ path, err });
            return null;
        },
    };
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);

    const source = file_reader.interface.allocRemainingAlignedSentinel(
        gpa,
        .limited(max_bytes),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            report.* = try std.fmt.allocPrint(gpa, "cannot read {s}: {t}", .{ path, err });
            return null;
        },
    };
    defer gpa.free(source);

    return parse(gpa, source, report);
}

pub fn defaultPath(gpa: Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) {
            const path = try std.fmt.allocPrint(gpa, "{s}/delta/config.zon", .{xdg});
            return path;
        }
    }

    if (environ.get("HOME")) |home| {
        if (home.len > 0) {
            const path = try std.fmt.allocPrint(gpa, "{s}/.config/delta/config.zon", .{home});
            return path;
        }
    }

    return null;
}

test "an empty config is all defaults" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    var loaded = (try parse(gpa, ".{}", &report)).?;
    defer loaded.deinit();

    try std.testing.expectEqual(@as(i32, 8), loaded.config.gaps.between);
    try std.testing.expectEqual(Cursor.Warp.focus, loaded.config.input.cursor.warp);
    try std.testing.expect(report == null);
}

test "a partial config leaves the rest at defaults" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    var loaded = (try parse(gpa,
        \\.{
        \\    .gaps = .{ .between = 4 },
        \\    .input = .{ .cursor = .{ .warp = .none } },
        \\}
    , &report)).?;
    defer loaded.deinit();

    try std.testing.expectEqual(@as(i32, 4), loaded.config.gaps.between);
    try std.testing.expectEqual(@as(i32, 8), loaded.config.gaps.edge);
    try std.testing.expectEqual(Cursor.Warp.none, loaded.config.input.cursor.warp);
    try std.testing.expectEqual(@as(i32, 2), loaded.config.border.width);
}

test "strings are owned by the arena" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    var loaded = (try parse(gpa,
        \\.{ .on_error = .{ "notify-send", "delta" } }
    , &report)).?;
    defer loaded.deinit();

    try std.testing.expectEqualStrings("notify-send", loaded.config.on_error.?[0]);
}

test "an unknown field names itself" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    try std.testing.expect(try parse(gpa, ".{ .gaps_in = 4 }", &report) == null);

    try std.testing.expect(std.mem.indexOf(u8, report.?, "gaps_in") != null);
}

test "a syntax error reports a line" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    try std.testing.expect(try parse(gpa,
        \\.{
        \\    .gaps = .{ .between = 4 .edge = 8 },
        \\}
    , &report) == null);
    try std.testing.expect(std.mem.indexOf(u8, report.?, "2:") != null);
}

test "validation rejects what the type system cannot" {
    const gpa = std.testing.allocator;

    {
        var report: ?[]const u8 = null;
        defer if (report) |r| gpa.free(r);
        try std.testing.expect(try parse(gpa, ".{ .gaps = .{ .between = 7 } }", &report) == null);
        try std.testing.expect(std.mem.indexOf(u8, report.?, "even") != null);
    }
    {
        var report: ?[]const u8 = null;
        defer if (report) |r| gpa.free(r);
        try std.testing.expect(try parse(gpa, ".{ .layout = .{ .split_bias = 0 } }", &report) == null);
        try std.testing.expect(std.mem.indexOf(u8, report.?, "split_bias") != null);
    }
    {
        var report: ?[]const u8 = null;
        defer if (report) |r| gpa.free(r);
        try std.testing.expect(try parse(gpa, ".{ .gaps = .{ .between = true } }", &report) == null);
    }
}

test "bindings parse and resolve their keysyms" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    var loaded = (try parse(gpa,
        \\.{
        \\    .bindings = .{
        \\        .{ .mods = .{.super}, .key = "Return", .action = .{ .spawn = .{"ghostty"} } },
        \\        .{ .mods = .{ .super, .shift }, .key = "q", .action = .close },
        \\        .{ .key = "F1", .action = .toggle_floating },
        \\    },
        \\}
    , &report)).?;
    defer loaded.deinit();

    const bindings = loaded.config.bindings.?;
    try std.testing.expectEqual(@as(usize, 3), bindings.len);
    try std.testing.expectEqual(xkb.Keysym.Return, bindings[0].keysym().?);
    try std.testing.expectEqual(xkb.Keysym.q, bindings[1].keysym().?);
    try std.testing.expectEqual(xkb.Keysym.F1, bindings[2].keysym().?);

    try std.testing.expectEqual(@as(usize, 0), bindings[2].mods.len);
}

test "an unknown key name is rejected by name" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    try std.testing.expect(try parse(gpa,
        \\.{ .bindings = .{ .{ .key = "Retrun", .action = .close } } }
    , &report) == null);

    try std.testing.expect(std.mem.indexOf(u8, report.?, "Retrun") != null);
}

test "keysym names are case sensitive" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    var loaded = (try parse(gpa,
        \\.{ .bindings = .{
        \\    .{ .key = "a", .action = .close },
        \\    .{ .key = "A", .action = .close },
        \\} }
    , &report)).?;
    defer loaded.deinit();

    const bindings = loaded.config.bindings.?;
    try std.testing.expect(bindings[0].keysym().? != bindings[1].keysym().?);
}

test "no bindings and default bindings are different things" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    var absent = (try parse(gpa, ".{}", &report)).?;
    defer absent.deinit();
    try std.testing.expect(absent.config.bindings == null);

    var empty = (try parse(gpa, ".{ .bindings = .{} }", &report)).?;
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.config.bindings.?.len);
}

test "a config that is not a struct is rejected" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    try std.testing.expect(try parse(gpa, "42", &report) == null);
    try std.testing.expect(report.?.len > 0);
}

test "a failed parse frees everything it allocated" {
    const gpa = std.testing.allocator;

    const broken = [_][:0]const u8{
        ".{ .unknown = 1 }",
        ".{ .gaps = .{ .between = 7 } }",
        ".{ .gaps = .{ .between = 4 .edge = 8 } }",
        ".{ .bindings = .{ .{ .key = \"Nope\", .action = .close } } }",
        ".{ .on_error = .{ \"notify-send\", \"x\" }, .unknown = 1 }",
        "42",
    };

    for (broken) |source| {
        var report: ?[]const u8 = null;
        defer if (report) |r| gpa.free(r);

        try std.testing.expect(try parse(gpa, source, &report) == null);
    }
}

test "a config with strings survives being freed" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    var loaded = (try parse(gpa,
        \\.{
        \\    .on_error = .{ "notify-send", "delta" },
        \\    .bindings = .{ .{ .key = "Return", .action = .{ .spawn = .{"ghostty"} } } },
        \\}
    , &report)).?;
    loaded.deinit();
}

test "rules match on app_id, title and dialog" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    var loaded = (try parse(gpa,
        \\.{
        \\    .window_rules = .{
        \\        .{
        \\            .matches = .{ .{ .app_id = "vesktop" } },
        \\            .open_workspace = 4,
        \\        },
        \\        .{
        \\            .matches = .{ .{ .dialog = true } },
        \\            .open_floating = true,
        \\            .open_warp = false,
        \\        },
        \\        .{
        \\            .matches = .{ .{ .app_id = "zen", .title = "*Picture-in-Picture*" } },
        \\            .open_floating = true,
        \\        },
        \\    },
        \\}
    , &report)).?;
    defer loaded.deinit();

    const config = loaded.config;

    const vesktop = config.resolve(.{ .app_id = "vesktop", .title = "Discord", .dialog = false });
    try std.testing.expectEqual(@as(?u32, 4), vesktop.workspace);
    try std.testing.expectEqual(@as(?bool, null), vesktop.floating);

    const dialog = config.resolve(.{ .app_id = "nautilus", .title = "Open File", .dialog = true });
    try std.testing.expectEqual(@as(?bool, true), dialog.floating);
    try std.testing.expectEqual(@as(?bool, false), dialog.warp);

    // Both conditions in one Match must hold.
    const pip = config.resolve(.{ .app_id = "zen", .title = "Zen — Picture-in-Picture", .dialog = false });
    try std.testing.expectEqual(@as(?bool, true), pip.floating);

    const plain = config.resolve(.{ .app_id = "zen", .title = "Zen Browser", .dialog = false });
    try std.testing.expectEqual(@as(?bool, null), plain.floating);
}

test "later rules win, and excludes beat matches" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    var loaded = (try parse(gpa,
        \\.{
        \\    .window_rules = .{
        \\        .{ .matches = .{ .{ .dialog = true } }, .open_floating = true },
        \\        .{
        \\            .matches = .{ .{ .app_id = "steam" } },
        \\            .excludes = .{ .{ .title = "Friends List" } },
        \\            .open_floating = false,
        \\        },
        \\        .{ .excludes = .{ .{ .app_id = "zen" } }, .open_focused = true },
        \\    },
        \\}
    , &report)).?;
    defer loaded.deinit();

    const config = loaded.config;

    // The second rule overrides the first for a steam dialog.
    const steam = config.resolve(.{ .app_id = "steam", .title = "Settings", .dialog = true });
    try std.testing.expectEqual(@as(?bool, false), steam.floating);

    // ...unless excluded, in which case only the first rule applied.
    const friends = config.resolve(.{ .app_id = "steam", .title = "Friends List", .dialog = true });
    try std.testing.expectEqual(@as(?bool, true), friends.floating);

    // A rule with no matches applies to everything the excludes let through.
    try std.testing.expectEqual(
        @as(?bool, true),
        config.resolve(.{ .app_id = "foot", .title = "foot", .dialog = false }).focused,
    );
    try std.testing.expectEqual(
        @as(?bool, null),
        config.resolve(.{ .app_id = "zen", .title = "Zen", .dialog = false }).focused,
    );
}

test "a window with no app id does not match a pattern for one" {
    const gpa = std.testing.allocator;
    var report: ?[]const u8 = null;
    defer if (report) |r| gpa.free(r);

    var loaded = (try parse(gpa,
        \\.{ .window_rules = .{ .{ .matches = .{ .{ .app_id = "*" } }, .open_floating = true } } }
    , &report)).?;
    defer loaded.deinit();

    // Xwayland windows clear their app id, and "*" asks about a value that is
    // not there rather than about the empty string.
    try std.testing.expectEqual(
        @as(?bool, null),
        loaded.config.resolve(.{ .app_id = null, .title = "x", .dialog = false }).floating,
    );
}
