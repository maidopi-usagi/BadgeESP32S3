const std = @import("std");
pub const physics = @import("physics.zig");
pub const Reading = struct { accel: [3]f32, gyro: [3]f32, time_ms: u64 };
pub const State = struct {
    world: physics.World = .{},
    face: u8 = 1,
    has_result: bool = false,
    cocked: bool = false,
    last_ms: ?u64 = null,
    last_toss_ms: ?u64 = null,
    accumulator: u32 = 0,
    sensor_ms: ?u64 = null,
    force: physics.Vec = .{ .z = -physics.gravity },
    tray_omega: physics.Vec = .{},
    dropped_ms: u64 = 0,

    pub fn rolling(self: *const State) bool {
        return !self.world.sleeping;
    }
    pub fn roll(self: *State, now_ms: u64, seed: u32) bool {
        if (self.last_toss_ms) |last| if (now_ms -| last < 180) return false;
        self.last_toss_ms = now_ms;
        self.world.toss(seed);
        self.has_result = false;
        self.cocked = false;
        return true;
    }
    pub fn reenter(self: *State, now_ms: u64) void {
        self.last_ms = now_ms;
        self.accumulator = 0;
        self.sensor_ms = null;
        self.tray_omega = .{};
    }
    fn input(self: *State, sample: ?Reading, now_ms: u64) void {
        const reading = sample orelse {
            self.sensor_ms = null;
            self.tray_omega = .{};
            self.force = .{ .z = -physics.gravity };
            return;
        };
        if (reading.time_ms > now_ms or now_ms - reading.time_ms > 250) return self.input(null, now_ms);
        for (reading.accel, reading.gyro) |a, g| {
            if (!std.math.isFinite(a) or !std.math.isFinite(g) or @abs(a) > 4.1 or @abs(g) > 8) return self.input(null, now_ms);
        }
        if (self.sensor_ms) |last| if (reading.time_ms == last) return;
        const omega = (physics.Vec{ .x = reading.gyro[0], .y = reading.gyro[1], .z = reading.gyro[2] }).limited(8);
        if (self.sensor_ms) |last| {
            if (reading.time_ms > last and reading.time_ms - last <= 150) self.world.turnTray(omega.sub(self.tray_omega));
        }
        self.sensor_ms = reading.time_ms;
        self.tray_omega = omega;
        self.force = .{ .x = -reading.accel[0] * physics.gravity, .y = -reading.accel[1] * physics.gravity, .z = -reading.accel[2] * physics.gravity };
    }
    pub fn advance(self: *State, now_ms: u64, sample: ?Reading) bool {
        self.input(sample, now_ms);
        const last = self.last_ms orelse {
            self.last_ms = now_ms;
            return false;
        };
        if (now_ms <= last) return false;
        self.last_ms = now_ms;
        const elapsed = now_ms - last;
        const accepted: u32 = @intCast(@min(elapsed, 50));
        self.dropped_ms += elapsed - accepted;
        self.accumulator += accepted * physics.hz;
        var had_motion = self.rolling();
        while (self.accumulator >= 1000) {
            self.accumulator -= 1000;
            self.world.step(self.force, self.tray_omega);
            had_motion = had_motion or self.rolling();
        }
        if (self.rolling()) {
            self.has_result = false;
            self.cocked = false;
        }
        if (had_motion and self.world.sleeping) {
            const result = self.world.resultFace();
            self.has_result = result != null;
            self.cocked = result == null;
            if (result) |face| self.face = face;
            return true;
        }
        return false;
    }
};

test "a physically cocked die asks for another tilt or toss without inventing a result" {
    const extent = physics.half * (0.5 + 0.8660254);
    var state: State = .{ .world = .{
        .position = .{ .y = -physics.tray_y + extent, .z = extent },
        .orientation = .{ .x = 0.5, .w = 0.8660254 },
        .sleeping = false,
    } };
    state.reenter(0);
    var now: u64 = 33;
    while (state.rolling() and now < 18000) : (now += 33) _ = state.advance(now, null);
    try std.testing.expect(!state.rolling() and state.cocked and !state.has_result);
    const pose = state.world.orientation;
    try std.testing.expect(state.roll(now, 7));
    try std.testing.expect(state.rolling() and !state.cocked and !state.has_result);
    try std.testing.expectEqualDeep(pose, state.world.orientation);
}

test "physical dice fixed steps agree across display rates and freeze across reentry" {
    var fast: State = .{};
    var slow: State = .{};
    _ = fast.roll(0, 1234567);
    _ = slow.roll(0, 1234567);
    fast.reenter(0);
    slow.reenter(0);
    var time: u64 = 16;
    while (time < 3000) : (time += 16) _ = fast.advance(time, null);
    _ = fast.advance(3000, null);
    time = 33;
    while (time < 3000) : (time += 33) _ = slow.advance(time, null);
    _ = slow.advance(3000, null);
    try std.testing.expectEqualDeep(fast.world, slow.world);
    const before = slow.world;
    slow.reenter(100_000);
    try std.testing.expectEqualDeep(before, slow.world);
    try std.testing.expect(!slow.advance(100_000, null));
    try std.testing.expectEqualDeep(before, slow.world);
    _ = slow.advance(101_000, null);
    try std.testing.expectEqual(@as(u64, 950), slow.dropped_ms);
}

test "IMU drives force continuously and gyro changes apply once per fresh sample" {
    var state: State = .{};
    state.input(.{ .accel = .{ 0.5, -0.25, 1 }, .gyro = .{ 0, 0, 0 }, .time_ms = 10 }, 10);
    try std.testing.expectEqual(physics.Vec{ .x = -9, .y = 4.5, .z = -18 }, state.force);
    const sample: Reading = .{ .accel = .{ 0, 0, 1 }, .gyro = .{ 2, 0, 0 }, .time_ms = 30 };
    state.input(sample, 30);
    const spin = state.world.angular_velocity;
    try std.testing.expect(spin.x < -1.9);
    state.input(sample, 40);
    try std.testing.expectEqualDeep(spin, state.world.angular_velocity);
    state.input(.{ .accel = .{ std.math.nan(f32), 0, 1 }, .gyro = .{ 0, 0, 0 }, .time_ms = 50 }, 50);
    try std.testing.expectEqual(physics.Vec{ .z = -18 }, state.force);
    try std.testing.expectEqual(physics.Vec{}, state.tray_omega);
}
