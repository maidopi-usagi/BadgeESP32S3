//! Algorithm reference: https://box2d.org/files/ErinCatto_SequentialImpulses_GDC2006.pdf
const std = @import("std");
const math = @import("../simulation/math.zig");
pub const Vec = math.Vec;
pub const hz = 240;
pub const dt: f32 = 1.0 / @as(f32, hz);
pub const max_bodies = 24;
pub const center: Vec = .{ .x = 80, .y = 80 };
pub const radius: f32 = 70;
pub const wall: u8 = 255;
const max_contacts = max_bodies * (max_bodies - 1) + max_bodies * 4;
pub const Shape = enum(u8) { ball, box };
inline fn low(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
inline fn high(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
inline fn clamp(v: f32, a: f32, b: f32) f32 {
    return low(b, high(a, v));
}
inline fn cross(a: Vec, b: Vec) f32 {
    return a.x * b.y - a.y * b.x;
}
inline fn perp(a: Vec) Vec {
    return .{ .x = -a.y, .y = a.x };
}
inline fn spin(w: f32, r: Vec) Vec {
    return perp(r).scale(w);
}
pub inline fn rotate(r: Vec, v: Vec) Vec {
    return .{ .x = r.x * v.x - r.y * v.y, .y = r.y * v.x + r.x * v.y };
}
pub inline fn unrotate(r: Vec, v: Vec) Vec {
    return .{ .x = r.x * v.x + r.y * v.y, .y = r.x * v.y - r.y * v.x };
}
fn turn(r: Vec, angle: f32) Vec {
    const a2 = angle * angle;
    const c = 1 - a2 * 0.5 + a2 * a2 * (1.0 / 24.0);
    const s = angle * (1 - a2 * (1.0 / 6.0) + a2 * a2 * (1.0 / 120.0));
    return rotate(.{ .x = c, .y = s }, r);
}
pub const Body = struct {
    position: Vec,
    velocity: Vec = .{},
    rotation: Vec = .{ .x = 1 },
    angular_velocity: f32 = 0,
    half: f32,
    inverse_mass: f32,
    inverse_inertia: f32,
    shape: Shape,
    pub fn make(shape: Shape, half: f32, position: Vec) Body {
        const mass = (if (shape == .ball) @as(f32, std.math.pi) else 4) * half * half * 0.01;
        const inertia = mass * half * half * (if (shape == .ball) @as(f32, 0.5) else 2.0 / 3.0);
        return .{ .shape = shape, .half = half, .position = position, .inverse_mass = math.reciprocal(mass), .inverse_inertia = math.reciprocal(inertia) };
    }
    pub fn extent(self: Body) f32 {
        return if (self.shape == .ball) self.half else self.half * (@abs(self.rotation.x) + @abs(self.rotation.y));
    }
    pub fn corners(self: Body) [4]Vec {
        const x = self.rotation.scale(self.half);
        const y = perp(self.rotation).scale(self.half);
        return .{ self.position.sub(x).sub(y), self.position.add(x).sub(y), self.position.add(x).add(y), self.position.sub(x).add(y) };
    }
};
pub const Grab = struct { body: u8, local: Vec, target: Vec, velocity: Vec = .{} };
pub const Grabs = struct { items: [5]Grab = undefined, count: u8 = 0 };
const Hit = struct { point: Vec, normal: Vec, separation: f32, feature: u16 = 0 };
const Manifold = struct { points: [2]Hit = undefined, count: u8 = 0 };
fn circleCircle(a: Body, b: Body) Manifold {
    var m: Manifold = .{};
    const delta = b.position.sub(a.position);
    const d2 = delta.length2();
    const reach = a.half + b.half + 0.05;
    if (d2 > reach * reach) return m;
    const inv_d = if (d2 > 0.00001) math.inverseSqrt(d2) else 0;
    const normal: Vec = if (inv_d > 0) delta.scale(inv_d) else .{ .x = 1 };
    const distance = d2 * inv_d;
    m.points[0] = .{ .point = a.position.add(normal.scale(a.half + (distance - a.half - b.half) * 0.5)), .normal = normal, .separation = distance - a.half - b.half };
    m.count = 1;
    return m;
}
fn circleBox(a: Body, b: Body) Manifold {
    var m: Manifold = .{};
    const local = unrotate(b.rotation, a.position.sub(b.position));
    const closest: Vec = .{ .x = clamp(local.x, -b.half, b.half), .y = clamp(local.y, -b.half, b.half) };
    const delta = closest.sub(local);
    const d2 = delta.length2();
    if (d2 > (a.half + 0.05) * (a.half + 0.05)) return m;
    var normal: Vec = undefined;
    var separation: f32 = undefined;
    var point = closest;
    if (d2 > 0.00001) {
        const inv_d = math.inverseSqrt(d2);
        normal = rotate(b.rotation, delta.scale(inv_d));
        separation = d2 * inv_d - a.half;
    } else {
        const dx = b.half - @abs(local.x);
        const dy = b.half - @abs(local.y);
        const outward: Vec = if (dx < dy) .{ .x = if (local.x < 0) -1 else 1 } else .{ .y = if (local.y < 0) -1 else 1 };
        separation = -a.half - low(dx, dy);
        normal = rotate(b.rotation, outward).scale(-1);
        if (dx < dy) point.x = outward.x * b.half else point.y = outward.y * b.half;
    }
    const surface = b.position.add(rotate(b.rotation, point));
    m.points[0] = .{ .normal = normal, .separation = separation, .point = surface.add(a.position.add(normal.scale(a.half))).scale(0.5) };
    m.count = 1;
    return m;
}
fn projection(b: Body, axis: Vec) f32 {
    return b.half * (@abs(axis.dot(b.rotation)) + @abs(axis.dot(perp(b.rotation))));
}
fn boxBox(a: Body, b: Body) Manifold {
    var result: Manifold = .{};
    const axes = [_]Vec{ a.rotation, perp(a.rotation), b.rotation, perp(b.rotation) };
    const delta = b.position.sub(a.position);
    var overlap: f32 = 1e10;
    var axis_index: usize = 0;
    for (axes, 0..) |axis, i| {
        const depth = projection(a, axis) + projection(b, axis) - @abs(delta.dot(axis));
        if (depth < -0.05) return result;
        if (depth < overlap) {
            overlap = depth;
            axis_index = i;
        }
    }
    const normal = axes[axis_index].scale(if (delta.dot(axes[axis_index]) < 0) @as(f32, -1) else 1);
    const ref = if (axis_index < 2) a else b;
    const inc = if (axis_index < 2) b else a;
    const ref_n = normal.scale(if (axis_index < 2) @as(f32, 1) else -1);
    const tangent = perp(ref_n);
    const face = ref.position.add(ref_n.scale(ref.half));
    const dx = ref_n.dot(inc.rotation);
    const dy = ref_n.dot(perp(inc.rotation));
    const inc_x = @abs(dx) > @abs(dy);
    const inc_n = (if (inc_x) inc.rotation else perp(inc.rotation)).scale(if ((if (inc_x) dx else dy) > 0) @as(f32, -1) else 1);
    const inc_face = inc.position.add(inc_n.scale(inc.half));
    const offset = perp(inc_n).scale(inc.half);
    const p0 = inc_face.sub(offset);
    const line = offset.scale(2);
    const start = p0.sub(ref.position).dot(tangent);
    const span = line.dot(tangent);
    var t0: f32 = 0;
    var t1: f32 = 1;
    if (@abs(span) > 0.00001) {
        const inverse_span = (if (span < 0) @as(f32, -1) else 1) * math.reciprocal(@abs(span));
        const lo = (-ref.half - start) * inverse_span;
        const hi = (ref.half - start) * inverse_span;
        t0 = high(0, low(lo, hi));
        t1 = low(1, high(lo, hi));
        if (t0 > t1) return result;
    } else if (@abs(start) > ref.half) return result;
    for ([_]f32{ t0, t1 }, 0..) |t, i| {
        if (i == 1 and t1 - t0 < 0.00001) continue;
        const point = p0.add(line.scale(t));
        const separation = point.sub(face).dot(ref_n);
        if (separation > 0.05) continue;
        result.points[result.count] = .{ .point = point.sub(ref_n.scale(separation * 0.5)), .normal = normal, .separation = separation, .feature = @intCast(axis_index * 8 + @as(usize, if (inc_x) 0 else 4) + i) };
        result.count += 1;
    }
    return result;
}
fn collide(a: Body, b: Body) Manifold {
    if (a.shape == .ball and b.shape == .ball) return circleCircle(a, b);
    if (a.shape == .box and b.shape == .box) return boxBox(a, b);
    if (a.shape == .ball) return circleBox(a, b);
    var m = circleBox(b, a);
    for (m.points[0..m.count]) |*p| p.normal = p.normal.scale(-1);
    return m;
}
const Contact = struct {
    key: u32,
    a: u8,
    b: u8,
    normal: Vec,
    local_a: Vec,
    local_b: Vec,
    ra: Vec,
    rb: Vec,
    separation: f32,
    mass_n: f32,
    mass_t: f32,
    normal_impulse: f32 = 0,
    tangent_impulse: f32 = 0,
    bounce: f32 = 0,
};
pub const Stats = struct { candidates: u32 = 0, contacts: u32 = 0, grabbed: u32 = 0 };
pub const World = struct {
    bodies: [max_bodies]Body = undefined,
    count: u8 = max_bodies,
    buffers: [2][max_contacts]Contact = undefined,
    front: u1 = 0,
    contact_count: usize = 0,
    previous_count: usize = 0,
    order: [max_bodies]u8 = undefined,
    steps: u64 = 0,
    pub fn create(allocator: std.mem.Allocator) !*World {
        const self = try allocator.create(World);
        self.reset();
        return self;
    }
    pub fn reset(self: *World) void {
        self.count = max_bodies;
        self.front = 0;
        self.contact_count = 0;
        self.previous_count = 0;
        self.steps = 0;
        for (&self.bodies, 0..) |*body, i| {
            body.* = Body.make(if (i % 2 == 0) .ball else .box, if (i % 2 == 0) 8 + @as(f32, @floatFromInt(i % 3)) * 0.5 else 7 + @as(f32, @floatFromInt(i % 3)) * 0.5, .{ .x = 35 + @as(f32, @floatFromInt(i % 6)) * 18, .y = 43 + @as(f32, @floatFromInt(i / 6)) * 19 });
            body.velocity = .{ .x = if (i % 3 == 0) -16 else 12, .y = if (i % 4 == 0) -12 else 8 };
            body.angular_velocity = if (i % 2 == 0) 1.1 else -0.7;
            self.order[i] = @intCast(i);
        }
    }
    fn apply(self: *World, c: *const Contact, impulse: Vec) void {
        const a = &self.bodies[c.a];
        a.velocity = a.velocity.sub(impulse.scale(a.inverse_mass));
        a.angular_velocity -= a.inverse_inertia * cross(c.ra, impulse);
        if (c.b != wall) {
            const b = &self.bodies[c.b];
            b.velocity = b.velocity.add(impulse.scale(b.inverse_mass));
            b.angular_velocity += b.inverse_inertia * cross(c.rb, impulse);
        }
    }
    fn relative(self: *const World, c: Contact) Vec {
        const a = self.bodies[c.a];
        const av = a.velocity.add(spin(a.angular_velocity, c.ra));
        if (c.b == wall) return av.scale(-1);
        const b = self.bodies[c.b];
        return b.velocity.add(spin(b.angular_velocity, c.rb)).sub(av);
    }
    fn append(self: *World, ai: u8, bi: u8, hit: Hit) void {
        const a = self.bodies[ai];
        const ra = hit.point.sub(a.position);
        const rb: Vec = if (bi != wall) hit.point.sub(self.bodies[bi].position) else .{};
        const inv_m = a.inverse_mass + if (bi != wall) self.bodies[bi].inverse_mass else 0;
        const inv_i_b = if (bi != wall) self.bodies[bi].inverse_inertia else 0;
        const rn_a = cross(ra, hit.normal);
        const rn_b = cross(rb, hit.normal);
        const tangent = perp(hit.normal);
        const rt_a = cross(ra, tangent);
        const rt_b = cross(rb, tangent);
        var c: Contact = .{ .key = @as(u32, ai) << 24 | @as(u32, bi) << 16 | hit.feature, .a = ai, .b = bi, .normal = hit.normal, .local_a = unrotate(a.rotation, ra), .local_b = if (bi != wall) unrotate(self.bodies[bi].rotation, rb) else hit.point, .ra = ra, .rb = rb, .separation = hit.separation, .mass_n = math.reciprocal(inv_m + a.inverse_inertia * rn_a * rn_a + inv_i_b * rn_b * rn_b), .mass_t = math.reciprocal(inv_m + a.inverse_inertia * rt_a * rt_a + inv_i_b * rt_b * rt_b) };
        const closing = self.relative(c).dot(c.normal);
        if (closing < -16) c.bounce = -closing * (if (a.shape == .ball and (bi == wall or self.bodies[bi].shape == .ball)) @as(f32, 0.35) else 0.12);
        for (self.buffers[self.front ^ 1][0..self.previous_count]) |old| if (old.key == c.key and old.normal.dot(c.normal) > 0.95) {
            c.normal_impulse = old.normal_impulse;
            c.tangent_impulse = old.tangent_impulse;
            break;
        };
        std.debug.assert(self.contact_count < max_contacts);
        self.buffers[self.front][self.contact_count] = c;
        self.contact_count += 1;
    }
    fn buildContacts(self: *World) Stats {
        var stats: Stats = .{};
        var minimum: [max_bodies]f32 = undefined;
        var maximum: [max_bodies]f32 = undefined;
        for (self.bodies[0..self.count], 0..) |b, i| {
            const e = b.extent();
            minimum[i] = b.position.x - e;
            maximum[i] = b.position.x + e;
        }
        for (1..self.count) |i| {
            const item = self.order[i];
            var j = i;
            while (j > 0 and minimum[self.order[j - 1]] > minimum[item]) : (j -= 1) self.order[j] = self.order[j - 1];
            self.order[j] = item;
        }
        for (0..self.count) |i| {
            const ai = self.order[i];
            for (i + 1..self.count) |j| {
                const bi = self.order[j];
                if (minimum[bi] > maximum[ai] + 0.05) break;
                if (@abs(self.bodies[ai].position.y - self.bodies[bi].position.y) > self.bodies[ai].extent() + self.bodies[bi].extent() + 0.05) continue;
                stats.candidates += 1;
                const first = @min(ai, bi);
                const second = @max(ai, bi);
                const manifold = collide(self.bodies[first], self.bodies[second]);
                for (manifold.points[0..manifold.count]) |hit| self.append(first, second, hit);
            }
        }
        for (self.bodies[0..self.count], 0..) |b, i| {
            if (b.shape == .ball) {
                const radial = b.position.sub(center);
                const r2 = radial.length2();
                const limit = radius - b.half;
                if (r2 < (limit - 0.05) * (limit - 0.05)) continue;
                const inv_r = math.inverseSqrt(r2);
                const normal = radial.scale(inv_r);
                self.append(@intCast(i), wall, .{ .point = b.position.add(normal.scale(b.half)), .normal = normal, .separation = limit - r2 * inv_r });
            } else for (b.corners(), 0..) |point, feature| {
                const radial = point.sub(center);
                const r2 = radial.length2();
                if (r2 < (radius - 0.05) * (radius - 0.05)) continue;
                const inv_r = math.inverseSqrt(r2);
                self.append(@intCast(i), wall, .{ .point = point, .normal = radial.scale(inv_r), .separation = radius - r2 * inv_r, .feature = @intCast(feature) });
            }
        }
        stats.contacts = @intCast(self.contact_count);
        return stats;
    }
    fn solvePosition(self: *World, c: Contact) void {
        const a = &self.bodies[c.a];
        const ra = rotate(a.rotation, c.local_a);
        const pa = a.position.add(ra);
        const rb: Vec = if (c.b != wall) rotate(self.bodies[c.b].rotation, c.local_b) else .{};
        const pb: Vec = if (c.b != wall) self.bodies[c.b].position.add(rb) else c.local_b;
        const separation = c.separation + pb.sub(pa).dot(c.normal);
        const correction = clamp(0.3 * (separation + 0.025), -1, 0);
        if (correction == 0) return;
        const rn_a = cross(ra, c.normal);
        const rn_b = cross(rb, c.normal);
        const inverse_mass = a.inverse_mass + if (c.b != wall) self.bodies[c.b].inverse_mass else 0;
        const ib = if (c.b != wall) self.bodies[c.b].inverse_inertia else 0;
        const magnitude = -correction * math.reciprocal(inverse_mass + a.inverse_inertia * rn_a * rn_a + ib * rn_b * rn_b);
        const impulse = c.normal.scale(magnitude);
        a.position = a.position.sub(impulse.scale(a.inverse_mass));
        a.rotation = turn(a.rotation, -a.inverse_inertia * cross(ra, impulse));
        if (c.b != wall) {
            const b = &self.bodies[c.b];
            b.position = b.position.add(impulse.scale(b.inverse_mass));
            b.rotation = turn(b.rotation, b.inverse_inertia * cross(rb, impulse));
        }
    }
    pub noinline fn step(self: *World, gravity: Vec, grabs: []const Grab) Stats {
        std.debug.assert(self.count <= max_bodies and grabs.len <= 5);
        @setRuntimeSafety(false);
        self.previous_count = self.contact_count;
        self.contact_count = 0;
        self.front ^= 1;
        for (self.bodies[0..self.count]) |*b| {
            b.velocity = b.velocity.add(gravity.scale(dt)).scale(0.9997);
            b.angular_velocity *= 0.9997;
            const speed2 = b.velocity.length2();
            if (speed2 > 260 * 260) b.velocity = b.velocity.scale(260 * math.inverseSqrt(speed2));
            b.angular_velocity = clamp(b.angular_velocity, -18, 18);
            b.position = b.position.add(b.velocity.scale(dt));
            b.rotation = turn(b.rotation, b.angular_velocity * dt);
        }
        var stats = self.buildContacts();
        const constraints = self.buffers[self.front][0..self.contact_count];
        for (constraints) |*c| self.apply(c, c.normal.scale(c.normal_impulse).add(perp(c.normal).scale(c.tangent_impulse)));
        const Joint = struct { body: u8, r: Vec, target_velocity: Vec, bias: Vec, gamma: f32, xx: f32, xy: f32, yy: f32, limit: f32, impulse: Vec = .{} };
        var joints: [5]Joint = undefined;
        for (grabs, 0..) |g, i| {
            const b = self.bodies[g.body];
            const mass = math.reciprocal(b.inverse_mass);
            const omega: f32 = 2 * std.math.pi * 7;
            const damping = 2 * mass * 0.9 * omega;
            const stiffness = mass * omega * omega;
            const gamma = math.reciprocal(dt * (damping + dt * stiffness));
            const beta = dt * stiffness * gamma;
            const r = rotate(b.rotation, g.local);
            const kxx = b.inverse_mass + b.inverse_inertia * r.y * r.y + gamma;
            const kxy = -b.inverse_inertia * r.x * r.y;
            const kyy = b.inverse_mass + b.inverse_inertia * r.x * r.x + gamma;
            const inverse = math.reciprocal(kxx * kyy - kxy * kxy);
            joints[i] = .{ .body = g.body, .r = r, .target_velocity = g.velocity, .bias = b.position.add(r).sub(g.target).scale(beta), .gamma = gamma, .xx = kyy * inverse, .xy = -kxy * inverse, .yy = kxx * inverse, .limit = mass * 1800 * dt };
        }
        stats.grabbed = @intCast(grabs.len);
        for (0..8) |_| {
            for (joints[0..grabs.len]) |*joint| {
                const b = &self.bodies[joint.body];
                const v = b.velocity.add(spin(b.angular_velocity, joint.r)).sub(joint.target_velocity).add(joint.bias).add(joint.impulse.scale(joint.gamma));
                const change: Vec = .{ .x = -joint.xx * v.x - joint.xy * v.y, .y = -joint.xy * v.x - joint.yy * v.y };
                const old = joint.impulse;
                joint.impulse = old.add(change);
                if (joint.impulse.length2() > joint.limit * joint.limit) joint.impulse = joint.impulse.scale(joint.limit * math.inverseSqrt(joint.impulse.length2()));
                const impulse = joint.impulse.sub(old);
                b.velocity = b.velocity.add(impulse.scale(b.inverse_mass));
                b.angular_velocity += b.inverse_inertia * cross(joint.r, impulse);
            }
            for (constraints) |*c| {
                const vn = self.relative(c.*).dot(c.normal);
                const old_n = c.normal_impulse;
                c.normal_impulse = high(0, old_n + c.mass_n * (c.bounce - vn));
                self.apply(c, c.normal.scale(c.normal_impulse - old_n));
                const vt = self.relative(c.*).dot(perp(c.normal));
                const friction: f32 = if (self.bodies[c.a].shape == .ball) 0.2 else 0.4;
                const old_t = c.tangent_impulse;
                c.tangent_impulse = clamp(old_t - c.mass_t * vt, -friction * c.normal_impulse, friction * c.normal_impulse);
                self.apply(c, perp(c.normal).scale(c.tangent_impulse - old_t));
            }
        }
        for (0..3) |_| for (constraints) |c| self.solvePosition(c);
        for (self.bodies[0..self.count]) |*b| {
            b.rotation = b.rotation.scale(math.inverseSqrt(b.rotation.length2()));
            const speed2 = b.velocity.length2();
            if (speed2 > 260 * 260) b.velocity = b.velocity.scale(260 * math.inverseSqrt(speed2));
            b.angular_velocity = clamp(b.angular_velocity, -18, 18);
        }
        self.steps += 1;
        return stats;
    }
};

test "Rigid circle, corner and contained circle collisions have correct normals" {
    const a = Body.make(.ball, 8, .{ .x = 60, .y = 80 });
    const b = Body.make(.ball, 8, .{ .x = 75, .y = 80 });
    const m = collide(a, b);
    try std.testing.expectEqual(@as(u8, 1), m.count);
    try std.testing.expectApproxEqAbs(@as(f32, -1), m.points[0].separation, 0.001);
    try std.testing.expect(m.points[0].normal.x > 0.99);
    const box = Body.make(.box, 8, .{ .x = 80, .y = 80 });
    const inside = collide(Body.make(.ball, 3, .{ .x = 85, .y = 80 }), box);
    try std.testing.expect(inside.points[0].normal.x < -0.99);
    const corner = collide(Body.make(.ball, 3, .{ .x = 89, .y = 89 }), box);
    try std.testing.expectEqual(@as(u8, 1), corner.count);
    try std.testing.expect(corner.points[0].normal.x < 0 and corner.points[0].normal.y < 0);
}
test "Rigid clipped box faces produce two contacts and SAT rejects rotated gaps" {
    const a = Body.make(.box, 8, .{ .x = 70, .y = 80 });
    var b = Body.make(.box, 8, .{ .x = 85, .y = 80 });
    const m = collide(a, b);
    try std.testing.expectEqual(@as(u8, 2), m.count);
    for (m.points[0..m.count]) |p| try std.testing.expectApproxEqAbs(@as(f32, -1), p.separation, 0.001);
    b.rotation = .{ .x = 0.70710678, .y = 0.70710678 };
    b.position = .{ .x = 100, .y = 100 };
    try std.testing.expectEqual(@as(u8, 0), collide(a, b).count);
}
test "Rigid collision impulses conserve linear momentum and offset impact creates spin" {
    const world = try World.create(std.testing.allocator);
    defer std.testing.allocator.destroy(world);
    world.count = 2;
    world.bodies[0] = Body.make(.ball, 8, .{ .x = 60, .y = 84 });
    world.bodies[1] = Body.make(.box, 8, .{ .x = 75, .y = 80 });
    world.bodies[0].velocity = .{ .x = 80 };
    const before = world.bodies[0].velocity.scale(1 / world.bodies[0].inverse_mass);
    _ = world.step(.{}, &.{});
    const momentum = world.bodies[0].velocity.scale(1 / world.bodies[0].inverse_mass).add(world.bodies[1].velocity.scale(1 / world.bodies[1].inverse_mass));
    try std.testing.expectApproxEqAbs(before.x * 0.9997, momentum.x, 0.01);
    try std.testing.expect(@abs(world.bodies[1].angular_velocity) > 0.1);
}
test "Rigid pile with changing gravity and a grabbed corner remains finite and bounded" {
    const world = try World.create(std.testing.allocator);
    defer std.testing.allocator.destroy(world);
    for (0..2400) |i| {
        const t = @as(f32, @floatFromInt(i)) * 0.003;
        const g: Vec = .{ .x = @sin(t) * 300, .y = @cos(t) * 300 };
        const grab: Grab = .{ .body = 3, .local = .{ .x = 6, .y = 6 }, .target = center.add(.{ .x = @cos(t) * 35, .y = @sin(t) * 35 }) };
        _ = world.step(g, if (i < 800) &.{grab} else &.{});
        for (world.bodies) |b| {
            try std.testing.expect(std.math.isFinite(b.position.x) and std.math.isFinite(b.velocity.y));
            try std.testing.expectApproxEqAbs(@as(f32, 1), b.rotation.length2(), 0.00002);
            try std.testing.expect(b.velocity.length2() < 260 * 260 + 1);
            if (b.shape == .ball) try std.testing.expect(b.position.sub(center).length2() < (radius - b.half + 1) * (radius - b.half + 1)) else for (b.corners()) |p| try std.testing.expect(p.sub(center).length2() < (radius + 1) * (radius + 1));
        }
    }
}
