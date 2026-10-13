const std = @import("std");
pub const max_degrees = 8;
pub const max_angle: f32 = max_degrees * std.math.pi / 180.0;
pub const calibration_samples = 40;
pub const recenter_after_ms = 2000;
pub const Offset = struct { yaw: f32 = 0, pitch: f32 = 0 };
pub const Sample = struct { accel: [3]f32, gyro: [3]f32 }; // g, radians/second

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn normalized(v: [3]f32) [3]f32 {
    const length = @sqrt(dot(v, v));
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

pub const Filter = struct {
    calibrated: bool = false,
    calibration_count: u16 = 0,
    accel_sum: [3]f32 = @splat(0),
    gyro_sum: [3]f32 = @splat(0),
    reference: [3]f32 = .{ 0, 0, 1 },
    bias: [3]f32 = @splat(0),
    angles: [3]f32 = @splat(0),
    last_ms: ?u64 = null,
    offset: Offset = .{},
    recenters: u32 = 0,
    still_since_ms: ?u64 = null,
    still_reference: [3]f32 = .{ 0, 0, 1 },
    still_sum: [3]f32 = @splat(0),
    still_count: u16 = 0,
    still_recentered: bool = true,

    pub fn update(self: *Filter, sample: Sample, now_ms: u64) void {
        for (sample.accel ++ sample.gyro) |value| if (!std.math.isFinite(value)) return;
        if (self.last_ms != null and now_ms <= self.last_ms.?) return;
        const elapsed = if (self.last_ms) |last| @min(now_ms - last, 60) else 20;
        self.last_ms = now_ms;
        const gravity_length = @sqrt(dot(sample.accel, sample.accel));
        const gravity_valid = gravity_length > 0.85 and gravity_length < 1.15;
        if (!self.calibrated) {
            const stable = gravity_valid and dot(sample.gyro, sample.gyro) < 0.035 * 0.035 and
                (self.calibration_count == 0 or dot(normalized(sample.accel), normalized(self.accel_sum)) > 0.999);
            if (!stable) {
                self.calibration_count = 0;
                self.accel_sum = @splat(0);
                self.gyro_sum = @splat(0);
                return;
            }
            for (0..3) |i| {
                self.accel_sum[i] += sample.accel[i];
                self.gyro_sum[i] += sample.gyro[i];
            }
            self.calibration_count += 1;
            if (self.calibration_count == calibration_samples) {
                self.reference = normalized(self.accel_sum);
                for (0..3) |i| self.bias[i] = self.gyro_sum[i] / calibration_samples;
                self.calibrated = true;
                self.still_since_ms = now_ms;
                self.still_reference = self.reference;
            }
            return;
        }
        const dt = @as(f32, @floatFromInt(elapsed)) / 1000;
        for (0..3) |i| self.angles[i] += (sample.gyro[i] - self.bias[i]) * dt;
        const parallel = dot(self.angles, self.reference);
        if (gravity_valid) {
            const observed = cross(normalized(sample.accel), self.reference);
            const blend = dt / (0.45 + dt);
            for (0..3) |i| self.angles[i] += (observed[i] - (self.angles[i] - self.reference[i] * parallel)) * blend;
        }
        for (0..3) |i| {
            // Gravity cannot correct rotation around itself; gently recenter it.
            self.angles[i] -= self.reference[i] * parallel * dt / (8 + dt);
            self.angles[i] = std.math.clamp(self.angles[i], -0.6, 0.6);
        }
        self.offset = .{
            .yaw = std.math.clamp(-self.angles[1] * 0.9, -max_angle, max_angle),
            .pitch = std.math.clamp(-self.angles[0] * 0.9, -max_angle, max_angle),
        };
        self.recenterWhenStill(sample, now_ms, gravity_valid, elapsed);
    }

    fn recenterWhenStill(self: *Filter, sample: Sample, now_ms: u64, gravity_valid: bool, elapsed: u64) void {
        var speed_sq: f32 = 0;
        for (0..3) |i| speed_sq += (sample.gyro[i] - self.bias[i]) * (sample.gyro[i] - self.bias[i]);
        const stable = gravity_valid and speed_sq < 0.035 * 0.035 and elapsed < 60 and
            (self.still_since_ms == null or dot(normalized(sample.accel), self.still_reference) > 0.9994);
        if (!stable) {
            self.still_since_ms = null;
            self.still_sum = @splat(0);
            self.still_count = 0;
            self.still_recentered = false;
            return;
        }
        if (self.still_since_ms == null) {
            self.still_since_ms = now_ms;
            self.still_reference = normalized(sample.accel);
        }
        if (self.still_recentered) return;
        for (0..3) |i| self.still_sum[i] += sample.accel[i];
        self.still_count += 1;
        if (now_ms - self.still_since_ms.? < recenter_after_ms) return;
        self.reference = normalized(self.still_sum);
        self.angles = @splat(0);
        self.offset = .{};
        self.recenters +%= 1;
        self.still_recentered = true;
        self.still_reference = self.reference;
    }
};

pub const View = struct {
    filtered: Offset = .{},
    offset: Offset = .{},
    last_ms: ?u64 = null,

    pub fn advance(self: *View, target: Offset, now_ms: u64, touching: bool) bool {
        const last = self.last_ms orelse {
            self.last_ms = now_ms;
            return false;
        };
        if (now_ms <= last) return false;
        self.last_ms = now_ms;
        if (touching) return false;
        const dt = @as(f32, @floatFromInt(@min(now_ms - last, 120)));
        const blend = dt / (120 + dt);
        self.filtered.yaw += (target.yaw - self.filtered.yaw) * blend;
        self.filtered.pitch += (target.pitch - self.filtered.pitch) * blend;
        const next: Offset = .{ .yaw = quantize(self.filtered.yaw), .pitch = quantize(self.filtered.pitch) };
        const changed = next.yaw != self.offset.yaw or next.pitch != self.offset.pitch;
        self.offset = next;
        return changed;
    }
};

fn quantize(value: f32) f32 {
    return std.math.clamp(@round(value / 0.0025) * 0.0025, -max_angle, max_angle);
}

test "stationary calibration removes gyro bias and leaves idle pixels steady" {
    var filter: Filter = .{};
    const still: Sample = .{ .accel = .{ 0, 0, 1 }, .gyro = .{ 0.012, -0.009, 0.006 } };
    for (0..calibration_samples) |i| filter.update(still, i * 20);
    try std.testing.expect(filter.calibrated);
    for (calibration_samples..500) |i| filter.update(still, i * 20);
    try std.testing.expectApproxEqAbs(@as(f32, 0), filter.offset.yaw, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), filter.offset.pitch, 0.00001);
    var view: View = .{};
    _ = view.advance(.{}, 0, false);
    for (1..200) |i| try std.testing.expect(!view.advance(.{ .yaw = 0.0004, .pitch = -0.0004 }, i * 33, false));
}

test "tilt remains visible when held and gyro drives the gravity-blind axis" {
    var flat: Filter = .{};
    var upright: Filter = .{};
    for (0..calibration_samples) |i| {
        flat.update(.{ .accel = .{ 0, 0, 1 }, .gyro = @splat(0) }, i * 20);
        upright.update(.{ .accel = .{ 0, 1, 0 }, .gyro = @splat(0) }, i * 20);
    }
    for (calibration_samples..calibration_samples + 70) |i| flat.update(.{ .accel = .{ -0.342, 0, 0.94 }, .gyro = @splat(0) }, i * 20);
    try std.testing.expect(flat.offset.yaw < -0.08 and flat.offset.yaw >= -max_angle);
    for (calibration_samples..calibration_samples + 25) |i| upright.update(.{ .accel = .{ 0, 1, 0 }, .gyro = .{ 0, 0.5, 0 } }, i * 20);
    try std.testing.expect(upright.offset.yaw < -0.04);
}

test "holding a new posture recenters once after two seconds and restores tilt range" {
    var filter: Filter = .{};
    for (0..calibration_samples) |i| filter.update(.{ .accel = .{ 0, 0, 1 }, .gyro = @splat(0) }, i * 20);
    for (calibration_samples..60) |i| filter.update(.{ .accel = .{ 0, 1, 0 }, .gyro = .{ 1, 0, 0 } }, i * 20);
    const upright: Sample = .{ .accel = .{ 0, 1, 0 }, .gyro = @splat(0) };
    for (60..160) |i| filter.update(upright, i * 20);
    try std.testing.expectEqual(@as(u32, 0), filter.recenters);
    try std.testing.expect(@abs(filter.offset.pitch) > 0.01);
    filter.update(upright, 3199);
    try std.testing.expectEqual(@as(u32, 0), filter.recenters);
    filter.update(upright, 3200);
    try std.testing.expectEqual(@as(u32, 1), filter.recenters);
    try std.testing.expectEqual(Offset{}, filter.offset);
    for (161..300) |i| filter.update(upright, i * 20);
    try std.testing.expectEqual(@as(u32, 1), filter.recenters);
    for (300..350) |i| filter.update(.{ .accel = .{ 0, 0.985, -0.174 }, .gyro = @splat(0) }, i * 20);
    try std.testing.expect(filter.offset.pitch < -0.02);
    try std.testing.expectEqual(@as(u32, 1), filter.recenters);
}

test "motion rejects bad calibration and bounds shocks, gaps and visual changes" {
    var filter: Filter = .{};
    filter.update(.{ .accel = .{ 0, 0, 1 }, .gyro = .{ 0.055, 0, 0 } }, 0);
    try std.testing.expectEqual(@as(u16, 0), filter.calibration_count);
    for (1..calibration_samples + 1) |i| filter.update(.{ .accel = .{ 0, 0, 1 }, .gyro = @splat(0) }, i * 20);
    for (calibration_samples + 1..500) |i| {
        filter.update(.{ .accel = .{ 3, -2, 0 }, .gyro = .{ 4, -4, 3 } }, i * 500);
        try std.testing.expect(@abs(filter.offset.yaw) <= max_angle and @abs(filter.offset.pitch) <= max_angle);
    }
    const before = filter.offset;
    filter.update(.{ .accel = .{ std.math.nan(f32), 0, 1 }, .gyro = @splat(0) }, 999999);
    try std.testing.expectEqual(before, filter.offset);
    var view: View = .{};
    _ = view.advance(.{}, 0, false);
    _ = view.advance(.{ .yaw = max_angle }, 33, false);
    const held = view.offset;
    try std.testing.expect(!view.advance(.{ .yaw = -max_angle }, 4000, true));
    try std.testing.expectEqual(held, view.offset);
    for (1..100) |i| _ = view.advance(.{}, 4000 + i * 33, false);
    try std.testing.expectEqual(Offset{}, view.offset);
}
