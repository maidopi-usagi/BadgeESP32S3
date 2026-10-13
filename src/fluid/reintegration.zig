//! https://michaelmoroz.github.io/Reintegration-Tracking/
const std = @import("std");
const math = @import("../simulation/math.zig");
pub const Vec = math.Vec;
pub const Brush = struct { position: Vec = .{}, velocity: Vec = .{}, from: ?Vec = null };
pub const Stats = struct { pairs: u32 = 0, candidates: u32 = 0, speed_clamps: u32 = 0, stirred: u32 = 0 };
pub const size = 160;
pub const grid_side = 32;
const grid_count = grid_side * grid_side;
pub const center: Vec = .{ .x = 80, .y = 80 };
pub const radius: f32 = 70;
pub const dt: f32 = 1.0 / 120.0;
pub const h: f32 = 7.5;
const cell_size: f32 = 5;
const half_box: f32 = 2.5;
const speed_limit: f32 = 110;
const pressure_strength: f32 = 10_000;
const inverse_h2: f32 = 1 / (h * h);
const pressure_gradient: f32 = 24 / (std.math.pi * h * h * h * h);
// Trusted finite solver state only. Zig's floating @min/@max lower to
// newlib fminf/fmaxf on this target, spilling FPU registers at each overlap.
inline fn minFinite(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
inline fn maxFinite(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
pub const Cell = struct {
    position: Vec = .{},
    velocity: Vec = .{},
    density: f32 = 0,
    pressure_term: f32 = 0,
    acceleration: Vec = .{},
};
fn cellCenter(i: usize) Vec {
    return .{ .x = (@as(f32, @floatFromInt(i % grid_side)) + 0.5) * cell_size, .y = (@as(f32, @floatFromInt(i / grid_side)) + 0.5) * cell_size };
}
const valid: [grid_count]bool = blk: {
    @setEvalBranchQuota(30_000);
    var result: [grid_count]bool = undefined;
    for (&result, 0..) |*v, i| v.* = cellCenter(i).sub(center).length2() <= radius * radius;
    break :blk result;
};
pub const max_particles = blk: {
    @setEvalBranchQuota(30_000);
    var n: usize = 0;
    for (valid) |inside| if (inside) {
        n += 1;
    };
    break :blk n;
};
// Keep the complete 32x32 address space, but allocate only circular cells.
// This leaves internal RAM available for SPI's transient DMA bounce buffers.
const indices: [max_particles]u16 = blk: {
    @setEvalBranchQuota(30_000);
    var result: [max_particles]u16 = undefined;
    var n: usize = 0;
    for (valid, 0..) |inside, i| if (inside) {
        result[n] = @intCast(i);
        n += 1;
    };
    break :blk result;
};
const missing = std.math.maxInt(u16);
const lookup: [grid_count]u16 = blk: {
    @setEvalBranchQuota(30_000);
    var result: [grid_count]u16 = @splat(missing);
    for (indices, 0..) |i, n| result[i] = @intCast(n);
    break :blk result;
};
pub const World = struct {
    allocator: std.mem.Allocator,
    particles: []align(16) Cell,
    scratch: []align(16) Cell,
    count: usize = max_particles,
    reference_mass: f32 = 1,
    steps: u64 = 0,
    pub fn init(allocator: std.mem.Allocator) !World {
        const front = try allocator.alignedAlloc(Cell, .@"16", max_particles);
        errdefer allocator.free(front);
        var world: World = .{ .allocator = allocator, .particles = front, .scratch = try allocator.alignedAlloc(Cell, .@"16", max_particles) };
        world.reset();
        return world;
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.particles);
        self.allocator.free(self.scratch);
    }
    pub fn reset(self: *World) void {
        @memset(self.particles, .{});
        @memset(self.scratch, .{});
        var n: u32 = 0;
        for (indices) |i| if (cellCenter(i).y >= center.y) {
            n += 1;
        };
        self.reference_mass = 512 / @as(f32, @floatFromInt(n));
        var remaining: f32 = 512;
        var left = n;
        for (indices, 0..) |i, n_index| if (cellCenter(i).y >= center.y) {
            self.particles[n_index] = .{ .position = cellCenter(i), .density = if (left == 1) remaining else self.reference_mass };
            remaining -= self.particles[n_index].density;
            left -= 1;
        };
        self.steps = 0;
    }
    pub fn totalMass(self: *const World) f32 {
        var result: f32 = 0;
        for (self.particles) |p| result += p.density;
        return result;
    }
    pub fn momentum(self: *const World) Vec {
        var result: Vec = .{};
        for (self.particles) |p| result = result.add(p.velocity.scale(p.density));
        return result;
    }
    pub noinline fn forces(self: *World, gravity: Vec) Stats {
        @setRuntimeSafety(false);
        var stats: Stats = .{};
        for (self.particles) |*p| {
            p.acceleration = gravity;
            p.pressure_term = if (p.density > self.reference_mass) pressure_strength * (1 - self.reference_mass * math.reciprocal(p.density)) else 0;
        }
        const force_scale = pressure_gradient * cell_size * cell_size * math.reciprocal(self.reference_mass);
        for (self.particles, 0..) |*a, i| {
            if (a.density <= 0) continue;
            // The circular mask leaves an empty halo; all four indices fit.
            const flat = @as(usize, indices[i]);
            for ([_]usize{ flat + 1, flat + grid_side - 1, flat + grid_side, flat + grid_side + 1 }) |neighbor| {
                const j = lookup[neighbor];
                if (j == missing) continue;
                const b = &self.particles[j];
                if (b.density <= 0) continue;
                stats.candidates += 1;
                const delta = a.position.sub(b.position);
                const r2 = delta.length2();
                if (r2 >= h * h) continue;
                stats.pairs += 1;
                const q = 1 - r2 * inverse_h2;
                const pressure = force_scale * (a.pressure_term + b.pressure_term) * q * q;
                const viscosity = 0.35 * q * q;
                const f = delta.scale(pressure).add(b.velocity.sub(a.velocity).scale(viscosity));
                a.acceleration = a.acceleration.add(f.scale(b.density));
                b.acceleration = b.acceleration.sub(f.scale(a.density));
            }
        }
        return stats;
    }
    pub noinline fn transport(self: *World) void {
        @setRuntimeSafety(false);
        @memset(self.scratch, .{});
        const Deposit = struct { index: u16, point: Vec, area: f32, velocity: Vec };
        const inverse_reference = math.reciprocal(self.reference_mass);
        for (self.particles, 0..) |source, i| {
            if (source.density <= 0) continue;
            var velocity = source.velocity;
            var position = source.position.add(velocity.scale(dt));
            const radial = position.sub(center);
            const r2 = radial.length2();
            if (r2 > radius * radius) {
                const normal = radial.scale(math.inverseSqrt(r2));
                position = center.add(normal.scale(radius));
                const outward = velocity.dot(normal);
                if (outward > 0) velocity = velocity.sub(normal.scale(outward * 1.1));
            }
            // The diameter remains < two cells, so at most 3x3 deposits.
            const extent = half_box * minFinite(1.98, maxFinite(1, source.density * inverse_reference));
            const min_x = position.x - extent;
            const max_x = position.x + extent;
            const min_y = position.y - extent;
            const max_y = position.y + extent;
            const x0: usize = @intFromFloat(min_x * 0.2);
            const x1: usize = @intFromFloat(max_x * 0.2);
            const y0: usize = @intFromFloat(min_y * 0.2);
            const y1: usize = @intFromFloat(max_y * 0.2);
            var deposits: [9]Deposit = undefined;
            var n: usize = 0;
            var area: f32 = 0;
            for (y0..y1 + 1) |y| for (x0..x1 + 1) |x| {
                const cx = @as(f32, @floatFromInt(x)) * cell_size;
                const cy = @as(f32, @floatFromInt(y)) * cell_size;
                const lo: Vec = .{ .x = maxFinite(min_x, cx), .y = maxFinite(min_y, cy) };
                const hi: Vec = .{ .x = minFinite(max_x, cx + cell_size), .y = minFinite(max_y, cy + cell_size) };
                const overlap = maxFinite(0, hi.x - lo.x) * maxFinite(0, hi.y - lo.y);
                if (overlap <= 0) continue;
                var point = lo.add(hi).scale(0.5);
                var deposited_velocity = velocity;
                const offset = point.sub(center);
                const distance2 = offset.length2();
                if (distance2 > radius * radius) {
                    const inv_distance = math.inverseSqrt(distance2);
                    const normal = offset.scale(inv_distance);
                    // Reflect out-of-wall mass inward, preserving tangential
                    // velocity. Renormalizing only the surviving overlaps
                    // instead would introduce artificial spreading along walls.
                    point = center.add(offset.scale(2 * radius * inv_distance - 1));
                    const outward = deposited_velocity.dot(normal);
                    if (outward > 0) deposited_velocity = deposited_velocity.sub(normal.scale(outward * 1.1));
                }
                var index = lookup[@as(usize, @intFromFloat(point.y * 0.2)) * grid_side + @as(usize, @intFromFloat(point.x * 0.2))];
                if (index == missing) {
                    // Some circle fragments have a cell center outside the
                    // compact mask. An inset exceeding half the cell diagonal
                    // guarantees a valid destination without losing that mass.
                    const inward = point.sub(center);
                    point = center.add(inward.scale((radius - 4) * math.inverseSqrt(inward.length2())));
                    index = lookup[@as(usize, @intFromFloat(point.y * 0.2)) * grid_side + @as(usize, @intFromFloat(point.x * 0.2))];
                }
                deposits[n] = .{ .index = index, .point = point, .area = overlap, .velocity = deposited_velocity };
                area += overlap;
                n += 1;
            };
            if (n == 0) {
                deposits[0] = .{ .index = @intCast(i), .point = position, .area = 1, .velocity = velocity };
                n = 1;
                area = 1;
            }
            const inverse_area = math.reciprocal(area);
            var remaining = source.density;
            for (deposits[0..n], 0..) |d, k| {
                const mass = if (k + 1 == n) remaining else minFinite(remaining, source.density * d.area * inverse_area);
                remaining -= mass;
                const target = &self.scratch[d.index];
                target.density += mass;
                target.position = target.position.add(d.point.scale(mass));
                target.velocity = target.velocity.add(d.velocity.scale(mass));
            }
        }
        for (self.scratch, 0..) |*p, i| {
            if (p.density <= 0) continue;
            if (p.density < 1e-20) {
                p.position = cellCenter(indices[i]);
                p.velocity = .{};
                continue;
            }
            const inverse_mass = math.reciprocal(p.density);
            p.position = p.position.scale(inverse_mass);
            p.velocity = p.velocity.scale(inverse_mass);
            const radial = p.position.sub(center);
            const r2 = radial.length2();
            if (r2 > radius * radius) p.position = center.add(radial.scale(radius * math.inverseSqrt(r2)));
        }
        std.mem.swap([]align(16) Cell, &self.particles, &self.scratch);
    }
    pub noinline fn step(self: *World, gravity: Vec, brushes: []const Brush) Stats {
        std.debug.assert(brushes.len <= 5);
        @setRuntimeSafety(false);
        var stats = self.forces(gravity);
        const Prepared = struct { start: Vec, delta: Vec, inverse_length2: f32, velocity: Vec };
        var prepared: [5]Prepared = undefined;
        for (brushes, 0..) |brush, i| {
            const start = brush.from orelse brush.position;
            const delta = brush.position.sub(start);
            prepared[i] = .{ .start = start, .delta = delta, .inverse_length2 = if (delta.length2() > 0.001) math.reciprocal(delta.length2()) else 0, .velocity = brush.velocity };
        }
        for (self.particles) |*p| {
            if (p.density <= 0) continue;
            p.velocity = p.velocity.add(p.acceleration.scale(dt)).scale(0.9998);
            var strength: f32 = 0;
            var target: Vec = .{};
            var push: Vec = .{};
            for (prepared[0..brushes.len]) |brush| {
                const t = minFinite(1, maxFinite(0, p.position.sub(brush.start).dot(brush.delta) * brush.inverse_length2));
                const d = p.position.sub(brush.start.add(brush.delta.scale(t)));
                const r2 = d.length2();
                if (r2 >= 26 * 26) continue;
                const w = 1 - r2 * (1.0 / 676.0);
                const k = 180 * w * w;
                strength += k;
                target = target.add(brush.velocity.scale(k));
                push = push.add(d.scale(480 * w * w * (if (r2 < 4) @as(f32, 0.5) else math.inverseSqrt(r2))));
            }
            if (strength > 0) {
                p.velocity = p.velocity.add(target.add(push).scale(dt)).scale(math.reciprocal(1 + strength * dt));
                stats.stirred += 1;
            }
            const speed2 = p.velocity.length2();
            if (speed2 > speed_limit * speed_limit) {
                p.velocity = p.velocity.scale(speed_limit * math.inverseSqrt(speed2));
                stats.speed_clamps += 1;
            }
        }
        self.transport();
        self.steps += 1;
        return stats;
    }
    pub fn memoryBytes(self: World) usize {
        return (self.particles.len + self.scratch.len) * @sizeOf(Cell);
    }
};

test "RT box reintegration conserves mass and momentum through repeated splitting and merging" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();
    @memset(world.particles, .{});
    world.particles[lookup[16 * grid_side + 16]] = .{ .position = .{ .x = 82.5, .y = 82.5 }, .density = 2, .velocity = .{ .x = 14, .y = -11 } };
    world.particles[lookup[16 * grid_side + 17]] = .{ .position = .{ .x = 87.5, .y = 82.5 }, .density = 3, .velocity = .{ .x = -5, .y = 8 } };
    for (0..120) |_| world.transport();
    try std.testing.expectApproxEqAbs(@as(f32, 5), world.totalMass(), 0.001);
    const momentum = world.momentum();
    try std.testing.expectApproxEqAbs(@as(f32, 13), momentum.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 2), momentum.y, 0.01);
}
test "RT rotating gravity and two swept fingers preserve bounded finite state and total mass" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();
    for (0..720) |i| {
        const a = @as(f32, @floatFromInt(i)) * 0.02;
        const b: Brush = .{ .position = center.add(.{ .x = @cos(a) * 40, .y = @sin(a) * 40 }), .velocity = .{ .x = -@sin(a) * 150, .y = @cos(a) * 150 } };
        _ = world.step(.{ .x = @sin(a) * 120, .y = @cos(a) * 120 }, &.{ b, .{ .position = center, .velocity = .{ .x = 180 } } });
        for (world.particles, 0..) |p, j| {
            try std.testing.expect(p.density >= 0 and std.math.isFinite(p.density));
            if (p.density == 0) continue;
            try std.testing.expect(valid[indices[j]]);
            try std.testing.expect(std.math.isFinite(p.position.x) and std.math.isFinite(p.velocity.y));
            try std.testing.expect(p.position.sub(center).length2() <= radius * radius + 0.02);
            try std.testing.expect(p.velocity.length2() <= speed_limit * speed_limit + 0.1);
            const c = cellCenter(indices[j]);
            try std.testing.expect(@abs(p.position.x - c.x) <= cell_size * 0.5 + 0.02);
            try std.testing.expect(@abs(p.position.y - c.y) <= cell_size * 0.5 + 0.02);
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 512), world.totalMass(), 0.05);
    world.reset();
    try std.testing.expectEqual(@as(u64, 0), world.steps);
}
test "RT swept stirring transfers strong velocity without dropping source mass" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();
    @memset(world.particles, .{});
    world.particles[lookup[16 * grid_side + 16]] = .{ .position = center, .density = 2 };
    const b: Brush = .{ .from = .{ .x = 50, .y = 80 }, .position = .{ .x = 110, .y = 80 }, .velocity = .{ .x = 120 } };
    const stats = world.step(.{}, &.{b});
    try std.testing.expectEqual(@as(u32, 1), stats.stirred);
    try std.testing.expect(world.momentum().x / world.totalMass() > 60);
    try std.testing.expectApproxEqAbs(@as(f32, 2), world.totalMass(), 0.0001);
}

test "RT pressure and viscosity conserve internal momentum and viscosity dissipates relative motion" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();
    @memset(world.particles, .{});
    const a = &world.particles[lookup[16 * grid_side + 16]];
    const b = &world.particles[lookup[16 * grid_side + 17]];
    a.* = .{ .position = .{ .x = 82.5, .y = 82.5 }, .density = world.reference_mass * 2 };
    b.* = .{ .position = .{ .x = 87.5, .y = 82.5 }, .density = world.reference_mass * 1.5 };
    _ = world.forces(.{});
    const sum = a.acceleration.scale(a.density).add(b.acceleration.scale(b.density));
    try std.testing.expectApproxEqAbs(@as(f32, 0), sum.x, 0.001);
    try std.testing.expect(a.acceleration.x < 0 and b.acceleration.x > 0);
    a.density = world.reference_mass;
    b.density = world.reference_mass;
    a.velocity = .{ .x = 20 };
    b.velocity = .{ .x = -20 };
    _ = world.forces(.{});
    const power = a.acceleration.dot(a.velocity) * a.density + b.acceleration.dot(b.velocity) * b.density;
    try std.testing.expect(power < 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), a.acceleration.x * a.density + b.acceleration.x * b.density, 0.001);
}

test "RT sustained gravity does not collapse the fluid into a few wall cells" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();
    for (0..2400) |_| _ = world.step(.{ .y = 120 }, &.{});
    var max_mass: f32 = 0;
    var visible: usize = 0;
    for (world.particles) |p| {
        max_mass = @max(max_mass, p.density);
        if (p.density >= 0.05) visible += 1;
    }
    if (max_mass >= 3 * world.reference_mass or visible < 200) std.debug.print("RT settled: density={d}, visible={d}, mass={d}\n", .{ max_mass / world.reference_mass, visible, world.totalMass() });
    try std.testing.expect(max_mass < 3 * world.reference_mass);
    try std.testing.expect(visible >= 200);
    try std.testing.expectApproxEqAbs(@as(f32, 512), world.totalMass(), 0.05);
}

test "RT wall overlap reflection retains mass and slip velocity and keeps deposits in their cells" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();
    @memset(world.particles, .{});
    world.particles[lookup[2 * grid_side + 16]] = .{ .position = .{ .x = 80, .y = 10 }, .density = 2, .velocity = .{ .x = 30, .y = -20 } };
    world.transport();
    try std.testing.expectApproxEqAbs(@as(f32, 2), world.totalMass(), 0.0001);
    const velocity = world.momentum().scale(0.5);
    try std.testing.expect(velocity.x > 25 and velocity.y >= 0);
    for (world.particles, 0..) |p, i| {
        if (p.density <= 0) continue;
        const c = cellCenter(indices[i]);
        try std.testing.expect(@abs(p.position.x - c.x) <= cell_size * 0.5 + 0.02);
        try std.testing.expect(@abs(p.position.y - c.y) <= cell_size * 0.5 + 0.02);
        try std.testing.expect(p.position.sub(center).length2() <= radius * radius + 0.02);
    }
}
