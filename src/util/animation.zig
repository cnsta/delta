const std = @import("std");

const geom = @import("geom.zig");

pub const Curve = enum {
    linear,

    ease_out,

    ease_in_out,

    overshoot,

    pub fn apply(curve: Curve, t: f32) f32 {
        return switch (curve) {
            .linear => t,

            .ease_out => out: {
                const inv = 1.0 - t;
                break :out @mulAdd(f32, inv * inv, -inv, 1.0);
            },

            .ease_in_out => if (t < 0.5)
                4 * t * t * t
            else inout: {
                const c = @mulAdd(f32, -2.0, t, 2.0);
                break :inout @mulAdd(f32, -c / 2.0, c * c, 1.0);
            },

            .overshoot => back: {
                const back: f32 = 1.70158;
                const inv = t - 1.0;
                const inv2 = inv * inv;
                const inv3 = inv2 * inv;
                break :back @mulAdd(f32, back, inv3, @mulAdd(f32, back, inv2, inv3 + 1.0));
            },
        };
    }
};

pub const Fade = union(enum) {
    settled: f32,

    moving: struct {
        from: f32,
        to: f32,
        start: i64,
    },

    pub fn retarget(fade: *Fade, target: f32, now: i64, duration: i64, curve: Curve) void {
        if (fade.goal() == target) return;

        if (duration <= 0) {
            fade.* = .{ .settled = target };
            return;
        }

        const cur_val = fade.at(now, duration, curve);
        fade.* = .{ .moving = .{ .from = cur_val, .to = target, .start = now } };
    }

    pub fn at(fade: Fade, now: i64, duration: i64, curve: Curve) f32 {
        switch (fade) {
            .settled => |v| return v,
            .moving => |m| {
                const elapsed = now - m.start;
                if (elapsed >= duration) return m.to;
                if (elapsed <= 0) return m.from;

                const t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(duration));
                const eased = curve.apply(t);

                return m.from + (m.to - m.from) * eased;
            },
        }
    }

    pub fn done(fade: Fade, now: i64, duration: i64) bool {
        return switch (fade) {
            .settled => true,
            .moving => |m| now - m.start >= duration,
        };
    }

    pub fn goal(fade: Fade) f32 {
        return switch (fade) {
            .settled => |v| v,
            .moving => |m| m.to,
        };
    }
};

pub const Lerp = union(enum) {
    settled: geom.Point,

    moving: struct {
        from: geom.Point,
        to: geom.Point,

        start: i64,
    },

    pub const zero: Lerp = .{ .settled = geom.Point.zero };

    pub fn retarget(
        lerp: *Lerp,
        target: geom.Point,
        now: i64,
        duration: i64,
        curve: Curve,
    ) void {
        if (lerp.goal().eql(target)) return;

        if (duration <= 0) {
            lerp.* = .{ .settled = target };
            return;
        }

        const current = lerp.at(now, duration, curve);

        if (lerp.* == .settled and current.eql(target)) {
            lerp.* = .{ .settled = target };
            return;
        }

        lerp.* = .{ .moving = .{ .from = current, .to = target, .start = now } };
    }

    pub fn at(lerp: Lerp, now: i64, duration: i64, curve: Curve) geom.Point {
        switch (lerp) {
            .settled => |p| return p,
            .moving => |m| {
                const elapsed = now - m.start;
                if (elapsed >= duration) return m.to;
                if (elapsed <= 0) return m.from;

                const t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(duration));
                const eased = curve.apply(t);

                return .{
                    .x = m.from.x + scale(m.to.x - m.from.x, eased),
                    .y = m.from.y + scale(m.to.y - m.from.y, eased),
                };
            },
        }
    }

    pub fn done(lerp: Lerp, now: i64, duration: i64) bool {
        return switch (lerp) {
            .settled => true,
            .moving => |m| now - m.start >= duration,
        };
    }

    pub fn settle(lerp: *Lerp) void {
        switch (lerp.*) {
            .settled => {},
            .moving => |m| lerp.* = .{ .settled = m.to },
        }
    }

    pub fn goal(lerp: Lerp) geom.Point {
        return switch (lerp) {
            .settled => |p| p,
            .moving => |m| m.to,
        };
    }
};

fn scale(extent: i32, factor: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(extent)) * factor));
}

test "an animation begins at from and ends at to" {
    var lerp: Lerp = .zero;
    lerp.retarget(.{ .x = 100, .y = 200 }, 1000, 150, .ease_out);

    try std.testing.expectEqual(geom.Point{ .x = 0, .y = 0 }, lerp.at(1000, 150, .ease_out));
    try std.testing.expectEqual(geom.Point{ .x = 100, .y = 200 }, lerp.at(1150, 150, .ease_out));

    try std.testing.expectEqual(geom.Point{ .x = 100, .y = 200 }, lerp.at(9999, 150, .ease_out));
}

test "retargeting mid-flight starts from where the window is" {
    var lerp: Lerp = .zero;
    lerp.retarget(.{ .x = 100, .y = 0 }, 0, 100, .linear);

    const halfway = lerp.at(50, 100, .linear);
    try std.testing.expectEqual(@as(i32, 50), halfway.x);

    lerp.retarget(.{ .x = 200, .y = 0 }, 50, 100, .linear);
    try std.testing.expectEqual(halfway, lerp.at(50, 100, .linear));
}

test "a zero duration settles immediately" {
    var lerp: Lerp = .zero;
    lerp.retarget(.{ .x = 100, .y = 100 }, 0, 0, .ease_out);

    try std.testing.expect(lerp.done(0, 0));
    try std.testing.expectEqual(geom.Point{ .x = 100, .y = 100 }, lerp.at(0, 0, .ease_out));
}

test "curves start at zero and end at one" {
    for (std.enums.values(Curve)) |curve| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), curve.apply(0), 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 1), curve.apply(1), 0.001);
    }
}

test "overshoot actually overshoots and comes back" {
    var above = false;
    var t: f32 = 0;
    while (t <= 1.0) : (t += 0.01) {
        if (Curve.overshoot.apply(t) > 1.0) above = true;
    }

    try std.testing.expect(above);
    try std.testing.expectApproxEqAbs(@as(f32, 1), Curve.overshoot.apply(1), 0.001);
}

test "a fade reaches its target and stops" {
    var fade: Fade = .{ .settled = 1 };
    fade.retarget(0, 0, 100, .linear);

    try std.testing.expectApproxEqAbs(@as(f32, 1), fade.at(0, 100, .linear), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fade.at(50, 100, .linear), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), fade.at(100, 100, .linear), 0.001);

    try std.testing.expect(fade.done(100, 100));
}

test "retargeting to the current goal is a no-op" {
    var fade: Fade = .{ .settled = 1 };
    fade.retarget(0, 0, 100, .linear);

    fade.retarget(0, 50, 100, .linear);
    try std.testing.expect(fade.done(100, 100));
}

test "retargeting mid-flight uses the actual curve, not linear" {
    var fade: Fade = .{ .settled = 0 };
    fade.retarget(1, 0, 100, .ease_out);

    const halfway_eased = fade.at(50, 100, .ease_out);
    try std.testing.expect(halfway_eased != 0.5);

    fade.retarget(0, 50, 100, .ease_out);
    try std.testing.expectApproxEqAbs(halfway_eased, fade.at(50, 100, .ease_out), 0.001);
}
