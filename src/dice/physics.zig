const std = @import("std");
const fast = @import("../simulation/math.zig");
pub const hz = 240;
pub const dt: f32 = 1.0 / @as(f32, hz);
pub const half: f32 = 0.75;
pub const tray_x: f32 = 2.5;
pub const tray_y: f32 = 1.5;
pub const tray_height: f32 = 6;
pub const gravity: f32 = 18;
pub const tap_spin_scale: f32 = 10;
const max_angular_speed: f32 = 280;
const max_linear_speed: f32 = 140;
const launch_clearance = half * 1.7320508 + 0.035;
const inverse_inertia: f32 = 1.5 / (half * half); // Unit mass solid cube.

pub const Vec = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    pub inline fn add(a: Vec, b: Vec) Vec {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub inline fn sub(a: Vec, b: Vec) Vec {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub inline fn scale(a: Vec, k: f32) Vec {
        return .{ .x = a.x * k, .y = a.y * k, .z = a.z * k };
    }
    pub inline fn dot(a: Vec, b: Vec) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub inline fn cross(a: Vec, b: Vec) Vec {
        return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
    }
    pub inline fn length2(a: Vec) f32 {
        return a.dot(a);
    }
    pub fn limited(a: Vec, maximum: f32) Vec {
        const d = a.length2();
        return if (d > maximum * maximum) a.scale(maximum * fast.inverseSqrt(d)) else a;
    }
};

pub const Rotation = struct {
    x: Vec = .{ .x = 1 },
    y: Vec = .{ .y = 1 },
    z: Vec = .{ .z = 1 },
    pub fn apply(self: Rotation, v: Vec) Vec {
        return self.x.scale(v.x).add(self.y.scale(v.y)).add(self.z.scale(v.z));
    }
    pub fn compose(self: Rotation, other: Rotation) Rotation {
        return .{ .x = self.apply(other.x), .y = self.apply(other.y), .z = self.apply(other.z) };
    }
    pub fn euler(pitch: f32, yaw: f32, roll: f32) Rotation {
        const sx = @sin(pitch);
        const cx = @cos(pitch);
        const sy = @sin(yaw);
        const cy = @cos(yaw);
        const sz = @sin(roll);
        const cz = @cos(roll);
        return .{
            .x = .{ .x = cz * cy, .y = sz * cy, .z = -sy },
            .y = .{ .x = cz * sy * sx - sz * cx, .y = sz * sy * sx + cz * cx, .z = cy * sx },
            .z = .{ .x = cz * sy * cx + sz * sx, .y = sz * sy * cx - cz * sx, .z = cy * cx },
        };
    }
};

pub const Quaternion = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,
    pub fn integrate(self: *Quaternion, angular: Vec, seconds: f32) void {
        const q = self.*;
        const k = seconds * 0.5;
        self.x += k * (angular.x * q.w + angular.y * q.z - angular.z * q.y);
        self.y += k * (angular.y * q.w + angular.z * q.x - angular.x * q.z);
        self.z += k * (angular.z * q.w + angular.x * q.y - angular.y * q.x);
        self.w -= k * (angular.x * q.x + angular.y * q.y + angular.z * q.z);
        const inv = fast.inverseSqrt(self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w);
        self.x *= inv;
        self.y *= inv;
        self.z *= inv;
        self.w *= inv;
    }
    pub fn matrix(q: Quaternion) Rotation {
        return .{
            .x = .{ .x = 1 - 2 * (q.y * q.y + q.z * q.z), .y = 2 * (q.x * q.y + q.w * q.z), .z = 2 * (q.x * q.z - q.w * q.y) },
            .y = .{ .x = 2 * (q.x * q.y - q.w * q.z), .y = 1 - 2 * (q.x * q.x + q.z * q.z), .z = 2 * (q.y * q.z + q.w * q.x) },
            .z = .{ .x = 2 * (q.x * q.z + q.w * q.y), .y = 2 * (q.y * q.z - q.w * q.x), .z = 1 - 2 * (q.x * q.x + q.y * q.y) },
        };
    }
};

pub const vertices = [_]Vec{
    .{ .x = -1, .y = -1, .z = -1 }, .{ .x = 1, .y = -1, .z = -1 },
    .{ .x = 1, .y = 1, .z = -1 },   .{ .x = -1, .y = 1, .z = -1 },
    .{ .x = -1, .y = -1, .z = 1 },  .{ .x = 1, .y = -1, .z = 1 },
    .{ .x = 1, .y = 1, .z = 1 },    .{ .x = -1, .y = 1, .z = 1 },
};
pub const face_normals = [_]Vec{ .{ .z = 1 }, .{ .x = 1 }, .{ .y = 1 }, .{ .y = -1 }, .{ .x = -1 }, .{ .z = -1 } };
const Plane = struct { normal: Vec, u: Vec, v: Vec, offset: f32 };
const planes = [_]Plane{
    .{ .normal = .{ .z = 1 }, .u = .{ .x = 1 }, .v = .{ .y = 1 }, .offset = 0 },
    .{ .normal = .{ .z = -1 }, .u = .{ .x = 1 }, .v = .{ .y = 1 }, .offset = tray_height },
    .{ .normal = .{ .x = 1 }, .u = .{ .y = 1 }, .v = .{ .z = 1 }, .offset = tray_x },
    .{ .normal = .{ .x = -1 }, .u = .{ .y = 1 }, .v = .{ .z = 1 }, .offset = tray_x },
    .{ .normal = .{ .y = 1 }, .u = .{ .x = 1 }, .v = .{ .z = 1 }, .offset = tray_y },
    .{ .normal = .{ .y = -1 }, .u = .{ .x = 1 }, .v = .{ .z = 1 }, .offset = tray_y },
};
const Impulse = struct { normal: f32 = 0, u: f32 = 0, v: f32 = 0 };
const Contact = struct { r: Vec, key: u8, bounce: f32, mass_n: f32, mass_u: f32, mass_v: f32 };

pub const World = struct {
    position: Vec = .{ .z = half },
    velocity: Vec = .{},
    orientation: Quaternion = .{},
    angular_velocity: Vec = .{},
    launch_spin: ?Vec = null,
    launch_wait: u16 = 0,
    sleeping: bool = true,
    quiet_steps: u16 = 0,
    sleep_force: Vec = .{ .z = -gravity },
    cache: [48]Impulse = @splat(.{}),
    cache_dt: f32 = dt,
    steps: u64 = 0,
    substeps: u64 = 0,
    collisions: u64 = 0,

    pub fn wake(self: *World) void {
        self.sleeping = false;
        self.quiet_steps = 0;
    }
    pub fn toss(self: *World, seed: u32) void {
        var random: u32 = if (seed == 0) 0xA831C57B else seed;
        // Toss toward the free interior. Applying the spin while resting on the
        // floor turns it into an immediate collision instead of an airborne roll.
        self.velocity = self.velocity.add(.{ .x = -self.position.x * 6 + noise(&random) * 2, .y = -self.position.y * 8 + noise(&random), .z = 10.5 + noise(&random) * 1.5 });
        var axis: Vec = .{ .x = noise(&random), .y = noise(&random) };
        if (axis.length2() < 0.01) axis = .{ .x = 1 };
        const spin = 22 + noise(&random) * 4;
        self.launch_spin = axis.scale(spin * tap_spin_scale * fast.inverseSqrt(axis.length2())).add(.{ .z = noise(&random) * 10 * tap_spin_scale });
        self.launch_wait = 0;
        self.cache = @splat(.{});
        self.wake();
    }
    /// Change of the tray's angular velocity: Euler inertial impulse in its frame.
    pub fn turnTray(self: *World, delta: Vec) void {
        if (delta.length2() < 0.025 * 0.025) return;
        const bounded = delta.limited(4);
        self.angular_velocity = self.angular_velocity.sub(bounded);
        self.velocity = self.velocity.sub(bounded.cross(self.position));
        self.wake();
    }
    pub fn faceTowards(self: *const World, direction: Vec) u8 {
        const rotation = self.orientation.matrix();
        var best: f32 = -2;
        var face: u8 = 1;
        for (face_normals, 1..) |normal, value| {
            const score = rotation.apply(normal).dot(direction);
            if (score > best) {
                best = score;
                face = @intCast(value);
            }
        }
        return face;
    }
    pub fn resultFace(self: *const World) ?u8 {
        const face = self.faceTowards(.{ .z = 1 });
        return if (self.orientation.matrix().apply(face_normals[face - 1]).z >= 0.985) face else null;
    }
    pub fn corners(self: *const World) [8]Vec {
        const rotation = self.orientation.matrix();
        var result: [8]Vec = undefined;
        for (vertices, &result) |v, *p| p.* = self.position.add(rotation.apply(v.scale(half)));
        return result;
    }
    fn apply(self: *World, r: Vec, impulse: Vec) void {
        self.velocity = self.velocity.add(impulse);
        self.angular_velocity = self.angular_velocity.add(r.cross(impulse).scale(inverse_inertia));
    }
    fn relative(self: *const World, r: Vec) Vec {
        return self.velocity.add(self.angular_velocity.cross(r));
    }
    fn effectiveMass(r: Vec, n: Vec) f32 {
        return fast.reciprocal(1 + inverse_inertia * r.cross(n).length2());
    }

    pub fn step(self: *World, force: Vec, tray_omega: Vec) void {
        if (self.sleeping) {
            if (force.sub(self.sleep_force).length2() < 0.8 * 0.8 and tray_omega.length2() < 0.12 * 0.12) return;
            self.wake();
        }
        if (self.launch_spin) |spin| {
            if (self.position.z > launch_clearance and self.position.z < tray_height - launch_clearance and
                @abs(self.position.x) < tray_x - launch_clearance and @abs(self.position.y) < tray_y - launch_clearance)
            {
                self.angular_velocity = self.angular_velocity.add(spin);
                self.launch_spin = null;
                self.cache = @splat(.{});
            } else {
                self.launch_wait += 1;
                if (self.launch_wait >= hz / 2) self.launch_spin = null;
            }
        }
        self.velocity = self.velocity.scale(0.999).limited(max_linear_speed);
        self.angular_velocity = self.angular_velocity.scale(0.9985).limited(max_angular_speed);
        const turn2 = self.angular_velocity.length2() * dt * dt;
        const travel2 = self.velocity.length2() * dt * dt;
        var divisions: u8 = 1;
        while (divisions < 10) : (divisions += 1) {
            const n: f32 = @floatFromInt(divisions);
            if (turn2 <= n * n * 0.12 * 0.12 and travel2 <= n * n * 0.07 * 0.07) break;
        }
        var count: usize = 0;
        for (0..divisions) |_| count = self.integrateStep(force, tray_omega, dt / @as(f32, @floatFromInt(divisions)));
        self.steps += 1;
        self.substeps += divisions;
        // One corner or two edge contacts can be almost still at an unstable
        // balance point. Let gravity finish tipping it instead of freezing it.
        const quiet = self.launch_spin == null and count >= 3 and self.velocity.length2() < 0.055 * 0.055 and self.angular_velocity.length2() < 0.09 * 0.09 and tray_omega.length2() < 0.12 * 0.12;
        self.quiet_steps = if (quiet) self.quiet_steps + 1 else 0;
        if (self.quiet_steps >= 72) {
            self.sleeping = true;
            self.sleep_force = force;
            self.velocity = .{};
            self.angular_velocity = .{};
            self.cache = @splat(.{});
        }
    }

    fn integrateStep(self: *World, force: Vec, tray_omega: Vec, seconds: f32) usize {
        if (seconds != self.cache_dt) {
            const ratio = seconds * fast.reciprocal(self.cache_dt);
            for (&self.cache) |*impulse| {
                impulse.normal *= ratio;
                impulse.u *= ratio;
                impulse.v *= ratio;
            }
            self.cache_dt = seconds;
        }
        // Coriolis and centrifugal terms keep motion relative to the turning tray.
        const inertial = tray_omega.cross(self.velocity).scale(-2).sub(tray_omega.cross(tray_omega.cross(self.position)));
        self.velocity = self.velocity.add(force.add(inertial).scale(seconds)).limited(max_linear_speed);
        self.angular_velocity = self.angular_velocity.sub(tray_omega.cross(self.angular_velocity).scale(seconds)).limited(max_angular_speed);
        self.position = self.position.add(self.velocity.scale(seconds));
        self.orientation.integrate(self.angular_velocity, seconds);

        var contacts: [48]Contact = undefined;
        var count: usize = 0;
        const rotation = self.orientation.matrix();
        for (planes, 0..) |plane, p| {
            for (vertices, 0..) |vertex, i| {
                const key = p * 8 + i;
                const r = rotation.apply(vertex.scale(half));
                const separation = plane.normal.dot(self.position.add(r)) + plane.offset;
                if (separation > 0.003) {
                    self.cache[key] = .{};
                    continue;
                }
                const speed = self.relative(r).dot(plane.normal);
                contacts[count] = .{ .r = r, .key = @intCast(key), .bounce = if (speed < -0.9) -0.28 * speed else 0, .mass_n = effectiveMass(r, plane.normal), .mass_u = effectiveMass(r, plane.u), .mass_v = effectiveMass(r, plane.v) };
                count += 1;
                if (speed < -0.9) self.collisions += 1;
            }
        }
        for (contacts[0..count]) |contact| {
            const plane = planes[contact.key / 8];
            const warm = self.cache[contact.key];
            self.apply(contact.r, plane.normal.scale(warm.normal).add(plane.u.scale(warm.u)).add(plane.v.scale(warm.v)));
        }
        for (0..10) |_| {
            for (contacts[0..count]) |contact| {
                const plane = planes[contact.key / 8];
                const impulse = &self.cache[contact.key];
                const before = impulse.*;
                impulse.normal = @max(0, impulse.normal + contact.mass_n * (contact.bounce - self.relative(contact.r).dot(plane.normal)));
                self.apply(contact.r, plane.normal.scale(impulse.normal - before.normal));
                const speed = self.relative(contact.r);
                impulse.u -= contact.mass_u * speed.dot(plane.u);
                impulse.v -= contact.mass_v * speed.dot(plane.v);
                const limit = 0.48 * impulse.normal;
                const length2 = impulse.u * impulse.u + impulse.v * impulse.v;
                if (length2 > limit * limit and length2 > 0.00000001) {
                    const scale = limit * fast.inverseSqrt(length2);
                    impulse.u *= scale;
                    impulse.v *= scale;
                }
                self.apply(contact.r, plane.u.scale(impulse.u - before.u).add(plane.v.scale(impulse.v - before.v)));
            }
        }
        // Split positional correction: remove penetration without adding bounce energy.
        for (0..3) |_| {
            for (contacts[0..count]) |contact| {
                const plane = planes[contact.key / 8];
                const r = self.orientation.matrix().apply(vertices[contact.key % 8].scale(half));
                const separation = self.position.add(r).dot(plane.normal) + plane.offset;
                if (separation >= -0.0005) continue;
                const magnitude = @min(@as(f32, 0.04), -0.35 * (separation + 0.0005)) * effectiveMass(r, plane.normal);
                const correction = plane.normal.scale(magnitude);
                self.position = self.position.add(correction);
                self.orientation.integrate(r.cross(correction).scale(inverse_inertia), 1);
            }
        }
        const basis = self.orientation.matrix();
        const extent: Vec = .{ .x = half * (@abs(basis.x.x) + @abs(basis.y.x) + @abs(basis.z.x)), .y = half * (@abs(basis.x.y) + @abs(basis.y.y) + @abs(basis.z.y)), .z = half * (@abs(basis.x.z) + @abs(basis.y.z) + @abs(basis.z.z)) };
        self.position.x = std.math.clamp(self.position.x, -tray_x + extent.x, tray_x - extent.x);
        self.position.y = std.math.clamp(self.position.y, -tray_y + extent.y, tray_y - extent.y);
        self.position.z = std.math.clamp(self.position.z, extent.z, tray_height - extent.z);
        return count;
    }
};

fn noise(state: *u32) f32 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 17;
    state.* ^= state.* << 5;
    return @as(f32, @floatFromInt(state.* & 0xFFFF)) * (2.0 / 65535.0) - 1;
}

test "cube collision impulse creates the expected offset angular momentum" {
    var world: World = .{};
    world.apply(.{ .x = half }, .{ .z = 2 });
    try std.testing.expectApproxEqAbs(@as(f32, 2), world.velocity.z, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, -4), world.angular_velocity.y, 0.00001);
}

test "physical throws stay enclosed, settle and report the resulting orientation" {
    var seen: u6 = 0;
    var readable: usize = 0;
    for (1..25) |seed| {
        var world: World = .{};
        world.toss(@as(u32, @intCast(seed)) *% 0x9E3779B9);
        const impulse = world.launch_spin.?;
        const spin2 = impulse.x * impulse.x + impulse.y * impulse.y;
        try std.testing.expect(spin2 >= 179.9 * 179.9 and spin2 <= 260.1 * 260.1);
        var step: usize = 0;
        while (!world.sleeping and step < hz * 18) : (step += 1) {
            world.step(.{ .z = -gravity }, .{});
            for (world.corners()) |p| {
                try std.testing.expect(std.math.isFinite(p.x + p.y + p.z));
                try std.testing.expect(@abs(p.x) <= tray_x + 0.002 and @abs(p.y) <= tray_y + 0.002 and p.z >= -0.002 and p.z <= tray_height + 0.002);
            }
        }
        try std.testing.expect(world.sleeping);
        if (world.resultFace()) |face| {
            const normal = world.orientation.matrix().apply(face_normals[face - 1]);
            try std.testing.expect(normal.z >= 0.985);
            seen |= @as(u6, 1) << @as(u3, @intCast(face - 1));
            readable += 1;
        } else {
            var touching_wall = false;
            for (world.corners()) |p| touching_wall = touching_wall or @abs(p.x) > tray_x - 0.004 or @abs(p.y) > tray_y - 0.004;
            try std.testing.expect(touching_wall);
        }
        try std.testing.expect(world.collisions > 0);
        try std.testing.expect(world.substeps > world.steps);
    }
    try std.testing.expect(readable >= 20);
    try std.testing.expect(@popCount(seen) >= 4);
}

test "tap spin releases only with full clearance from every wall and preserves its energy" {
    for ([_]Vec{ .{ .z = half }, .{ .x = tray_x - half, .y = tray_y - half, .z = half }, .{ .x = -tray_x + half, .y = -tray_y + half, .z = half } }) |position| {
        var world: World = .{ .position = position };
        world.toss(17421);
        const spin2 = world.launch_spin.?.length2();
        try std.testing.expectEqualDeep(Vec{}, world.angular_velocity);
        try std.testing.expectEqualDeep(position, world.position);
        var released = false;
        for (0..hz / 2) |_| {
            const before = world.position;
            const impacts = world.collisions;
            world.step(.{ .z = -gravity }, .{});
            if (world.launch_spin == null) {
                try std.testing.expect(before.z > launch_clearance and before.z < tray_height - launch_clearance);
                try std.testing.expect(@abs(before.x) < tray_x - launch_clearance and @abs(before.y) < tray_y - launch_clearance);
                try std.testing.expectEqual(impacts, world.collisions);
                try std.testing.expect(world.angular_velocity.length2() > spin2 * 0.98);
                released = true;
                break;
            }
        }
        try std.testing.expect(released);
    }
}

test "continuous tray acceleration and rotation move a resting die without selecting a face" {
    var slide: World = .{};
    for (0..hz) |_| slide.step(.{ .x = 12, .z = -gravity }, .{});
    try std.testing.expect(slide.position.x > 0.5);
    var spin: World = .{};
    spin.turnTray(.{ .x = 2.5, .y = -1.2 });
    try std.testing.expect(!spin.sleeping and spin.angular_velocity.length2() > 5);
    for (0..hz * 2) |i| {
        const t = @as(f32, @floatFromInt(i)) * dt;
        spin.step(.{ .x = @sin(t * 7) * 35, .y = 12, .z = -10 + @cos(t * 8) * 30 }, .{ .x = 1.5, .y = -1 });
    }
    for (spin.corners()) |p| try std.testing.expect(std.math.isFinite(p.x + p.y + p.z) and p.z >= -0.002 and p.z <= tray_height + 0.002);
}
