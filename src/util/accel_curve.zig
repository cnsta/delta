const std = @import("std");

/// libinput's limits for libinput_config_accel_set_points().
pub const max_points = 64;
pub const max_step = 10000.0;
pub const max_value = 10000.0;

pub const Mode = enum { linear, natural, synchronous };

/// maccel's parameters, with its defaults. `offset` is shared by linear and
/// natural, as in github.com/Gnarus-G/maccel.
pub const Curve = struct {
    mode: Mode = .linear,
    sens_mult: f64 = 1,
    /// The mouse's DPI; speeds are normalized to 1000 DPI, as in maccel.
    /// Leave at 1000 if udev's hwdb already sets MOUSE_DPI for the mouse.
    input_dpi: f64 = 1000,
    /// The fastest input speed (counts/ms at 1000 DPI) the table covers.
    /// Beyond it libinput extrapolates linearly.
    max_speed: f64 = 64,

    // linear
    accel: f64 = 0,
    offset: f64 = 0,
    output_cap: f64 = 0,

    // natural
    decay_rate: f64 = 0.1,
    limit: f64 = 1.5,

    // synchronous
    gamma: f64 = 1,
    smooth: f64 = 0.5,
    motivity: f64 = 1.5,
    sync_speed: f64 = 5,
};

pub const Points = struct {
    step: f64,
    values: [max_points]f64,
};

pub fn sensitivity(c: Curve, speed: f64) f64 {
    const sens = switch (c.mode) {
        .linear => linear(c, speed),
        .natural => natural(c, speed),
        .synchronous => synchronous(c, speed),
    };
    return sens * c.sens_mult;
}

pub fn sample(c: Curve) Points {
    var points: Points = .{ .step = c.max_speed / (max_points - 1), .values = undefined };
    const dpi_factor = 1000 / c.input_dpi;
    for (&points.values, 0..) |*value, i| {
        const speed = @as(f64, @floatFromInt(i)) * points.step * dpi_factor;
        value.* = if (speed == 0) 0 else speed * sensitivity(c, speed);
    }
    return points;
}

/// Why `c` can't be sent to libinput, or null if it can.
pub fn check(c: Curve) ?[]const u8 {
    if (!(c.max_speed > 0 and c.max_speed / (max_points - 1) <= max_step))
        return "max_speed must be positive and at most 630000";
    if (!(c.input_dpi > 0)) return "input_dpi must be positive";
    if (!(c.sens_mult > 0)) return "sens_mult must be positive";
    if (c.mode == .synchronous) {
        if (!(c.motivity > 1)) return "motivity must be greater than 1";
        if (!(c.sync_speed > 0)) return "sync_speed must be positive";
        if (!(c.gamma > 0)) return "gamma must be positive";
        if (!(c.smooth >= 0)) return "smooth must not be negative";
    }
    const points = sample(c);
    for (points.values) |value| {
        if (!(value >= 0 and value <= max_value))
            return "the curve leaves libinput's 0 to 10000 output range; lower max_speed or the acceleration";
    }
    return null;
}

fn linear(c: Curve, speed: f64) f64 {
    if (speed <= c.offset) return 1;

    const x = speed - c.offset;
    var sens = c.accel * x * x / speed;
    var sign: f64 = 1;
    if (c.output_cap > 0) {
        var cap = c.output_cap - 1;
        if (cap < 0) {
            cap = -cap;
            sign = -1;
        }
        sens = @min(sens, cap);
    }
    return 1 + sign * sens;
}

fn natural(c: Curve, speed: f64) f64 {
    if (speed <= c.offset or c.limit <= 1 or c.decay_rate <= 0) return 1;

    const limit = c.limit - 1;
    const accel = c.decay_rate / @abs(limit);
    const constant = -limit / accel;
    const offset_x = c.offset - speed;
    const decay = @exp(accel * offset_x);
    const output = limit * (decay / accel - offset_x) + constant;
    return output / speed + 1;
}

fn synchronous(c: Curve, speed: f64) f64 {
    const log_motivity = @log(c.motivity);
    const gamma_const = c.gamma / log_motivity;
    const log_sync_speed = @log(c.sync_speed);
    const sharpness = if (c.smooth == 0) 16.0 else 0.5 / c.smooth;

    // From sharpness 16 on, maccel clamps linearly instead of using tanh.
    if (sharpness >= 16) {
        const log_space = gamma_const * (@log(speed) - log_sync_speed);
        if (log_space < -1) return 1 / c.motivity;
        if (log_space > 1) return c.motivity;
        return @exp(log_space * log_motivity);
    }

    if (speed == c.sync_speed) return 1;

    const log_diff = @log(speed) - log_sync_speed;
    const log_space = gamma_const * @abs(log_diff);
    const exponent = std.math.pow(f64, std.math.tanh(std.math.pow(f64, log_space, sharpness)), 1 / sharpness);
    return @exp(std.math.copysign(exponent, log_diff) * log_motivity);
}

const expectApprox = std.testing.expectApproxEqAbs;

test "linear: offset, quadratic gain and output cap" {
    const c: Curve = .{ .accel = 0.3, .offset = 2 };
    try expectApprox(1.0, sensitivity(c, 1), 1e-9);
    try expectApprox(1.3, sensitivity(c, 4), 1e-9); // 1 + 0.3 * 2² / 4

    const capped: Curve = .{ .accel = 1, .output_cap = 2 };
    try expectApprox(2.0, sensitivity(capped, 10), 1e-9);
    const below_one: Curve = .{ .accel = 1, .output_cap = 0.5 };
    try expectApprox(0.5, sensitivity(below_one, 10), 1e-9);
}

test "natural approaches its limit" {
    const c: Curve = .{ .mode = .natural };
    try expectApprox(1.2838338, sensitivity(c, 10), 1e-6);
    try expectApprox(1.5, sensitivity(c, 1e6), 1e-4);
    try expectApprox(1.0, sensitivity(.{ .mode = .natural, .limit = 1 }, 10), 1e-9);
}

test "synchronous is 1 at sync_speed and spans 1/motivity..motivity" {
    for ([_]f64{ 0.5, 0 }) |smooth| {
        const c: Curve = .{ .mode = .synchronous, .smooth = smooth };
        try expectApprox(1.0, sensitivity(c, 5), 1e-9);
        try expectApprox(1.5, sensitivity(c, 1000), 1e-6);
        try expectApprox(1.0 / 1.5, sensitivity(c, 0.01), 1e-6);
    }
}

test "sample: no acceleration is the identity, sens_mult and dpi scale it" {
    const identity = sample(.{});
    try expectApprox(64.0 / 63.0, identity.step, 1e-12);
    for (identity.values, 0..) |value, i| {
        try expectApprox(@as(f64, @floatFromInt(i)) * identity.step, value, 1e-9);
    }

    const scaled = sample(.{ .sens_mult = 2, .input_dpi = 2000 });
    try expectApprox(identity.values[10], scaled.values[10], 1e-9);
}

test "check rejects curves libinput would refuse" {
    try std.testing.expect(check(.{}) == null);
    try std.testing.expect(check(.{ .mode = .synchronous }) == null);
    try std.testing.expect(check(.{ .mode = .natural }) == null);
    try std.testing.expect(check(.{ .max_speed = 0 }) != null);
    try std.testing.expect(check(.{ .mode = .synchronous, .motivity = 1 }) != null);
    try std.testing.expect(check(.{ .accel = 100, .max_speed = 1000 }) != null);
}
