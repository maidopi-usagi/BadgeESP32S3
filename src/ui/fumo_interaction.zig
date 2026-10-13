const std = @import("std");
pub const idle_resume_ms = 8000;
pub const parallax_angle_limit: f32 = 8 * std.math.pi / 180.0;

pub const Pose = struct {
    yaw: f32 = 0,
    pitch: f32 = 0.12,
    scale_xz: f32 = 1,
    scale_y: f32 = 1,
    jump: f32 = 0,
    view_yaw: f32 = 0,
    view_pitch: f32 = 0,
};
pub const PointerEvent = @import("pointer.zig").Event;
pub const Action = enum { none, tap, drag };
const Press = struct { x: i32, y: i32, time_ms: u64, yaw: f32, pitch: f32, dragged: bool = false };
const Phase = enum { rest, crouch, air, settle };

pub const State = struct {
    pose: Pose = .{},
    auto_rotate: bool = true,
    last_ms: ?u64 = null,
    last_touch_ms: ?u64 = null,
    press: ?Press = null,
    dirty: bool = false,
    phase: Phase = .rest,
    crouch_left: f32 = 0,
    jump_velocity: f32 = 0,
    x_velocity: f32 = 0,
    y_velocity: f32 = 0,

    pub fn advance(self: *State, now_ms: u64) bool {
        self.tick(now_ms);
        const changed = self.dirty;
        self.dirty = false;
        return changed;
    }

    fn tick(self: *State, now_ms: u64) void {
        const last = self.last_ms orelse {
            self.last_ms = now_ms;
            return;
        };
        if (now_ms <= last) return;
        self.last_ms = now_ms;
        const elapsed = @min(now_ms - last, 120);
        var remaining = @as(f32, @floatFromInt(elapsed)) / 1000;
        var rotation_ms = elapsed;
        if (!self.auto_rotate and self.press == null) {
            if (self.last_touch_ms) |touched| {
                const deadline = touched +| idle_resume_ms;
                if (now_ms >= deadline) {
                    self.auto_rotate = true;
                    rotation_ms = @min(elapsed, now_ms - deadline);
                }
            }
        }
        if (self.auto_rotate and self.press == null) {
            if (rotation_ms > 0) {
                self.pose.yaw = wrap(self.pose.yaw + @as(f32, @floatFromInt(rotation_ms)) * (2 * std.math.pi / 18000.0));
                self.dirty = true;
            }
        }
        if (self.phase == .rest) return;
        self.dirty = true;
        while (remaining > 0.000001) {
            const dt = @min(remaining, 0.008);
            remaining -= dt;
            self.step(dt);
        }
    }

    fn step(self: *State, dt: f32) void {
        if (self.phase == .crouch) {
            self.crouch_left -= dt;
            if (self.crouch_left <= 0) {
                self.phase = .air;
                self.jump_velocity = 1.8;
                self.y_velocity += 2.5;
            }
        }
        if (self.phase == .air) {
            self.jump_velocity -= 9.8 * dt;
            self.pose.jump += self.jump_velocity * dt;
            if (self.pose.jump > 0.20) {
                self.pose.jump = 0.20;
                self.jump_velocity = @min(self.jump_velocity, 0);
            }
            if (self.pose.jump <= 0) {
                self.pose.jump = 0;
                self.jump_velocity = 0;
                self.phase = .settle;
                self.y_velocity -= 2.8;
                self.x_velocity += 0.8;
            }
        }
        const crouching = self.phase == .crouch;
        const damping = @exp(-11 * dt);
        self.x_velocity = (self.x_velocity + ((if (crouching) @as(f32, 1.10) else 1) - self.pose.scale_xz) * 52 * dt) * damping;
        self.y_velocity = (self.y_velocity + ((if (crouching) @as(f32, 0.80) else 1) - self.pose.scale_y) * 52 * dt) * damping;
        self.pose.scale_xz = std.math.clamp(self.pose.scale_xz + self.x_velocity * dt, 0.90, 1.16);
        self.pose.scale_y = std.math.clamp(self.pose.scale_y + self.y_velocity * dt, 0.72, 1.16);
        if (self.phase == .settle and @abs(self.pose.scale_xz - 1) < 0.001 and @abs(self.pose.scale_y - 1) < 0.001 and @abs(self.x_velocity) < 0.005 and @abs(self.y_velocity) < 0.005) {
            self.pose.scale_xz = 1;
            self.pose.scale_y = 1;
            self.x_velocity = 0;
            self.y_velocity = 0;
            self.phase = .rest;
        }
    }

    pub fn bounce(self: *State) void {
        if (self.pose.jump > 0) {
            self.phase = .air;
            self.jump_velocity = 1.8;
        } else {
            self.phase = .crouch;
            self.crouch_left = 0.065;
        }
        self.x_velocity = 0.65;
        self.y_velocity = -3.2;
        self.dirty = true;
    }

    pub fn pointer(self: *State, event: PointerEvent, x: i32, y: i32, now_ms: u64) Action {
        self.tick(now_ms);
        if (event == .cancel) {
            if (self.press != null) self.last_touch_ms = now_ms;
            self.press = null;
            return .none;
        }
        if (event == .down) {
            self.last_touch_ms = now_ms;
            self.auto_rotate = false;
            self.press = .{ .x = x, .y = y, .time_ms = now_ms, .yaw = self.pose.yaw, .pitch = self.pose.pitch };
            return .none;
        }
        const pressed = if (self.press) |*p| p else return .none;
        self.last_touch_ms = now_ms;
        const dx = x - pressed.x;
        const dy = y - pressed.y;
        if (dx * dx + dy * dy > 12 * 12) pressed.dragged = true;
        if (pressed.dragged) {
            self.auto_rotate = false;
            const yaw = wrap(pressed.yaw + @as(f32, @floatFromInt(dx)) * 0.012);
            const pitch = std.math.clamp(pressed.pitch + @as(f32, @floatFromInt(dy)) * 0.006, -0.55, 0.85);
            self.dirty = self.dirty or yaw != self.pose.yaw or pitch != self.pose.pitch;
            self.pose.yaw = yaw;
            self.pose.pitch = pitch;
        }
        if (event != .up) return .none;
        const dragged = pressed.dragged;
        const is_tap = !dragged and now_ms >= pressed.time_ms and now_ms - pressed.time_ms <= 350;
        self.press = null;
        if (is_tap) {
            self.bounce();
            return .tap;
        }
        return if (dragged) .drag else .none;
    }
};

test "idle resumes rotation after release with no catch-up or angle reset" {
    var state: State = .{};
    _ = state.pointer(.down, 100, 100, 100);
    _ = state.pointer(.move, 200, 150, 200);
    _ = state.pointer(.up, 200, 150, 300);
    _ = state.advance(300);
    const held_yaw = state.pose.yaw;
    const held_pitch = state.pose.pitch;
    try std.testing.expect(!state.advance(8299));
    try std.testing.expect(!state.auto_rotate);
    try std.testing.expect(!state.advance(8300));
    try std.testing.expect(state.auto_rotate);
    try std.testing.expectEqual(held_yaw, state.pose.yaw);
    try std.testing.expect(state.advance(8333));
    try std.testing.expectApproxEqAbs(held_yaw + @as(f32, 33 * (2 * std.math.pi / 18000.0)), state.pose.yaw, 0.00001);
    try std.testing.expectEqual(held_pitch, state.pose.pitch);
}

test "held touches block auto rotation and new touch restarts idle timer" {
    var state: State = .{};
    _ = state.pointer(.down, 100, 100, 0);
    _ = state.advance(10000);
    try std.testing.expect(!state.auto_rotate);
    _ = state.pointer(.up, 100, 100, 10001);
    _ = state.advance(18000);
    try std.testing.expect(!state.auto_rotate);
    _ = state.pointer(.down, 100, 100, 18000);
    _ = state.pointer(.cancel, 100, 100, 18010);
    _ = state.advance(26009);
    try std.testing.expect(!state.auto_rotate);
    _ = state.advance(26010);
    try std.testing.expect(state.auto_rotate);
}

fn wrap(angle: f32) f32 {
    const turn: f32 = 2 * std.math.pi;
    return angle - @floor((angle + std.math.pi) / turn) * turn;
}

test "drag rotates both axes, clamps pitch, and returning to start stays a drag" {
    var state: State = .{ .auto_rotate = false };
    _ = state.pointer(.down, 100, 100, 0);
    _ = state.pointer(.move, 200, 180, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), state.pose.yaw, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.60), state.pose.pitch, 0.0001);
    _ = state.pointer(.move, 465, 465, 150);
    try std.testing.expectEqual(@as(f32, 0.85), state.pose.pitch);
    try std.testing.expect(@abs(state.pose.yaw) <= std.math.pi);
    _ = state.pointer(.move, 100, 100, 180);
    _ = state.advance(181);
    _ = state.pointer(.move, 100, 100, 190);
    try std.testing.expect(!state.advance(191));
    try std.testing.expectEqual(Action.drag, state.pointer(.up, 100, 100, 200));
    try std.testing.expectEqual(Phase.rest, state.phase);
    try std.testing.expect(!state.auto_rotate);
    try std.testing.expect(!state.advance(201));
    try std.testing.expect(!state.advance(250));
}

test "small quick tap bounces; held, cancelled and release-only touches do not" {
    var state: State = .{ .auto_rotate = false };
    try std.testing.expectEqual(Action.none, state.pointer(.up, 100, 100, 0));
    _ = state.pointer(.down, 100, 100, 10);
    try std.testing.expectEqual(Action.none, state.pointer(.up, 100, 100, 400));
    _ = state.pointer(.down, 100, 100, 410);
    _ = state.pointer(.cancel, 100, 100, 420);
    try std.testing.expectEqual(Action.none, state.pointer(.up, 100, 100, 430));
    _ = state.pointer(.down, 100, 100, 440);
    try std.testing.expectEqual(Action.tap, state.pointer(.up, 106, 102, 520));
    try std.testing.expectEqual(Phase.crouch, state.phase);
}

test "bounce squashes, leaves the floor, lands, and settles without idle redraw" {
    var state: State = .{ .auto_rotate = false };
    _ = state.advance(0);
    state.bounce();
    _ = state.advance(48);
    try std.testing.expect(state.pose.scale_y < 0.9 and state.pose.scale_xz > 1);
    try std.testing.expectEqual(@as(f32, 0), state.pose.jump);
    _ = state.advance(160);
    try std.testing.expect(state.pose.jump > 0.1);
    var now: u64 = 176;
    while (now <= 3000) : (now += 16) _ = state.advance(now);
    try std.testing.expectEqual(Phase.rest, state.phase);
    try std.testing.expectEqual(@as(f32, 0), state.pose.jump);
    try std.testing.expectEqual(@as(f32, 1), state.pose.scale_y);
    try std.testing.expect(!state.advance(now));
}

test "rapid taps and long frame gaps keep spring and jump bounded" {
    var state: State = .{ .auto_rotate = false };
    _ = state.advance(0);
    for (1..500) |i| {
        if (i % 4 == 0) state.bounce();
        _ = state.advance(i * 17);
        try std.testing.expect(state.pose.scale_y >= 0.72 and state.pose.scale_y <= 1.16);
        try std.testing.expect(state.pose.scale_xz >= 0.90 and state.pose.scale_xz <= 1.16);
        try std.testing.expect(state.pose.jump >= 0 and state.pose.jump <= 0.20);
    }
    _ = state.advance(1_000_000);
    try std.testing.expect(std.math.isFinite(state.pose.jump) and std.math.isFinite(state.pose.scale_y));
}
