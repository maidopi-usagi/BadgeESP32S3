const std = @import("std");
pub const bucket_size = 8;
pub const max_samples = 65_535;
pub const max_bounces = 8;
const epsilon: f32 = 0.0002;
const far: f32 = 10_000;
const inv_pi: f32 = 1.0 / std.math.pi;

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
    pub inline fn scale(a: Vec, s: f32) Vec {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    pub inline fn mul(a: Vec, b: Vec) Vec {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }
    pub inline fn dot(a: Vec, b: Vec) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    inline fn cross(a: Vec, b: Vec) Vec {
        return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
    }
    inline fn component(a: Vec, comptime axis: usize) f32 {
        return switch (axis) {
            0 => a.x,
            1 => a.y,
            2 => a.z,
            else => unreachable,
        };
    }
    inline fn largest(a: Vec) f32 {
        return @max(a.x, @max(a.y, a.z));
    }
};

const white: Vec = .{ .x = 0.73, .y = 0.73, .z = 0.70 };
const red: Vec = .{ .x = 0.72, .y = 0.055, .z = 0.035 };
const green: Vec = .{ .x = 0.075, .y = 0.58, .z = 0.095 };
const emission: Vec = .{ .x = 12, .y = 11.4, .z = 10.2 };
const light_area: f32 = 0.64 * 0.60;
pub const Ray = struct { origin: Vec, direction: Vec };
pub const Hit = struct { distance: f32, point: Vec, normal: Vec, albedo: Vec, emitter: bool = false };

const Box = struct {
    center: Vec,
    half: Vec,
    cosine: f32,
    sine: f32,
    inline fn local(self: Box, v: Vec) Vec {
        return .{ .x = self.cosine * v.x - self.sine * v.z, .y = v.y, .z = self.sine * v.x + self.cosine * v.z };
    }
    inline fn world(self: Box, v: Vec) Vec {
        return .{ .x = self.cosine * v.x + self.sine * v.z, .y = v.y, .z = -self.sine * v.x + self.cosine * v.z };
    }
};
const boxes = [_]Box{
    .{ .center = .{ .x = -0.40, .y = 0.32, .z = 0.72 }, .half = .{ .x = 0.33, .y = 0.32, .z = 0.33 }, .cosine = 0.9510565, .sine = -0.3090170 },
    .{ .center = .{ .x = 0.38, .y = 0.65, .z = 1.25 }, .half = .{ .x = 0.32, .y = 0.65, .z = 0.32 }, .cosine = 0.9659258, .sine = 0.2588190 },
};

const Interval = struct { distance: f32, normal: Vec };
fn boxHit(ray: Ray, box: Box, limit: f32) ?Interval {
    return boxTest(ray, box, limit, true);
}
fn boxTest(ray: Ray, box: Box, limit: f32, comptime need_normal: bool) if (need_normal) ?Interval else bool {
    const miss: if (need_normal) ?Interval else bool = if (need_normal) null else false;
    const o = box.local(ray.origin.sub(box.center));
    const d = box.local(ray.direction);
    var near: f32 = -far;
    var exit: f32 = limit;
    var normal: Vec = .{};
    var exit_normal: Vec = .{};
    inline for (0..3) |axis| {
        const origin = o.component(axis);
        const direction = d.component(axis);
        const extent = box.half.component(axis);
        if (@abs(direction) < 1.0e-8) {
            if (origin < -extent or origin > extent) return miss;
        } else {
            const inverse = 1.0 / direction;
            const first = (-extent - origin) * inverse;
            const second = (extent - origin) * inverse;
            const lo = @min(first, second);
            const hi = @max(first, second);
            var n: Vec = .{};
            if (need_normal) switch (axis) {
                0 => n.x = if (direction > 0) -1 else 1,
                1 => n.y = if (direction > 0) -1 else 1,
                2 => n.z = if (direction > 0) -1 else 1,
                else => unreachable,
            };
            if (lo > near) {
                near = lo;
                if (need_normal) normal = n;
            }
            if (hi < exit) {
                exit = hi;
                if (need_normal) exit_normal = n.scale(-1);
            }
            if (near > exit) return miss;
        }
    }
    if (!need_normal) return near < limit and exit > epsilon;
    const distance = if (near > epsilon) near else exit;
    if (distance <= epsilon or distance >= limit) return null;
    return .{ .distance = distance, .normal = box.world(if (near > epsilon) normal else exit_normal) };
}

inline fn onLight(p: Vec) bool {
    return @abs(p.x) < 0.32 and p.z > 0.73 and p.z < 1.33;
}

pub fn intersect(ray: Ray) ?Hit {
    var nearest: f32 = far;
    var result: ?Hit = null;
    inline for (0..3) |axis| {
        const direction = ray.direction.component(axis);
        if (@abs(direction) > 1.0e-8) {
            const inverse = 1.0 / direction;
            const planes = if (axis == 2) 1 else 2;
            inline for (0..planes) |side| {
                const coordinate: f32 = if (axis == 0) (if (side == 0) -1 else 1) else if (axis == 1) (if (side == 0) 0 else 2) else 2;
                const distance = (coordinate - ray.origin.component(axis)) * inverse;
                if (distance > epsilon and distance < nearest) {
                    const p = ray.origin.add(ray.direction.scale(distance));
                    if (p.x >= -1.0001 and p.x <= 1.0001 and p.y >= -0.0001 and p.y <= 2.0001 and p.z >= -0.0001 and p.z <= 2.0001) {
                        var normal: Vec = .{};
                        switch (axis) {
                            0 => normal.x = if (side == 0) 1 else -1,
                            1 => normal.y = if (side == 0) 1 else -1,
                            2 => normal.z = -1,
                            else => unreachable,
                        }
                        nearest = distance;
                        result = .{ .distance = distance, .point = p, .normal = normal, .albedo = if (axis == 0) (if (side == 0) red else green) else white, .emitter = axis == 1 and side == 1 and onLight(p) };
                    }
                }
            }
        }
    }
    inline for (boxes) |box| {
        if (boxHit(ray, box, nearest)) |hit| {
            nearest = hit.distance;
            result = .{ .distance = hit.distance, .point = ray.origin.add(ray.direction.scale(hit.distance)), .normal = hit.normal, .albedo = white };
        }
    }
    return result;
}

/// The convex room cannot occlude a segment from an interior surface to its
/// ceiling light. Only the two boxes need a shadow test; the direction is the
/// unnormalized segment and its end is t=1, avoiding a square root/division.
fn occluded(origin: Vec, light: Vec) bool {
    const ray: Ray = .{ .origin = origin, .direction = light.sub(origin) };
    inline for (boxes) |box| if (boxTest(ray, box, 0.9999, false)) return true;
    return false;
}

fn hash(bits: u32) u32 {
    var x = bits;
    x ^= x >> 16;
    x *%= 0x7FEB352D;
    x ^= x >> 15;
    x *%= 0x846CA68B;
    return x ^ (x >> 16);
}
pub const Rng = struct {
    state: u32,
    pub fn init(seed: u32) Rng {
        return .{ .state = hash(seed) | 1 };
    }
    pub inline fn uniform(self: *Rng) f32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return @as(f32, @floatFromInt(x >> 8)) * (1.0 / 16_777_216.0);
    }
};

const DirectionSample = struct { direction: Vec, pdf: f32 };
fn cosineHemisphere(normal: Vec, rng: *Rng) DirectionSample {
    var x: f32 = undefined;
    var y: f32 = undefined;
    var r2: f32 = undefined;
    while (true) {
        x = 2 * rng.uniform() - 1;
        y = 2 * rng.uniform() - 1;
        r2 = x * x + y * y;
        if (r2 < 1) break;
    }
    const z = @sqrt(1 - r2);
    // Every scene normal is horizontal or vertical. Build a unit basis without
    // normalizing/crossing a nearly parallel arbitrary vector.
    const tangent: Vec = if (@abs(normal.y) > 0.99) .{ .x = 1 } else .{ .x = normal.z, .z = -normal.x };
    const bitangent = normal.cross(tangent);
    return .{ .direction = tangent.scale(x).add(bitangent.scale(y)).add(normal.scale(z)), .pdf = z * inv_pi };
}

pub const Counters = struct { paths: u32 = 0, rays: u32 = 0, shadow_rays: u32 = 0 };
fn radiance(primary: Ray, rng: *Rng, counters: *Counters) Vec {
    var ray = primary;
    var energy: Vec = .{};
    var throughput: Vec = .{ .x = 1, .y = 1, .z = 1 };
    var previous_point: Vec = .{};
    var previous_pdf: f32 = 0;
    counters.paths += 1;
    for (0..max_bounces) |depth| {
        counters.rays += 1;
        const hit = intersect(ray) orelse break;
        if (hit.emitter) {
            if (ray.direction.y > 0) {
                var weight: f32 = 1;
                if (depth > 0) {
                    const delta = hit.point.sub(previous_point);
                    const ratio = previous_pdf * light_area * ray.direction.y / delta.dot(delta);
                    weight = ratio * ratio / (1 + ratio * ratio);
                }
                energy = energy.add(throughput.mul(emission).scale(weight));
            }
            break;
        }
        const origin = hit.point.add(hit.normal.scale(epsilon));
        const light: Vec = .{ .x = (rng.uniform() - 0.5) * 0.64, .y = 2, .z = 0.73 + rng.uniform() * 0.60 };
        const delta = light.sub(hit.point);
        const cosine_product = hit.normal.dot(delta) * delta.y;
        if (cosine_product > 0) {
            const distance2 = delta.dot(delta);
            // p_bsdf / p_light also equals the Lambertian geometry factor.
            // This formulation cancels both inverse lengths and their sqrt.
            const ratio = light_area * inv_pi * cosine_product / (distance2 * distance2);
            counters.shadow_rays += 1;
            const weight = if (depth + 1 == max_bounces) ratio else ratio / (1 + ratio * ratio);
            if (!occluded(origin, light)) energy = energy.add(throughput.mul(hit.albedo).mul(emission).scale(weight));
        }
        if (depth + 1 == max_bounces) break;
        throughput = throughput.mul(hit.albedo);
        if (depth >= 2) {
            const survival = std.math.clamp(throughput.largest(), 0.05, 0.90);
            if (rng.uniform() >= survival) break;
            throughput = throughput.scale(1.0 / survival);
        }
        const outgoing = cosineHemisphere(hit.normal, rng);
        previous_point = hit.point;
        previous_pdf = outgoing.pdf;
        ray = .{ .origin = origin, .direction = outgoing.direction };
    }
    return energy;
}

fn toneChannel(linear: f32, levels: f32) u16 {
    const exposed = @max(@as(f32, 0), linear * 1.15);
    return @intFromFloat(@sqrt(exposed / (1 + exposed)) * levels + 0.5);
}
// Logarithmic IEEE-754 bins retain seven mantissa bits over [2^-16, 64].
// RGB565 quantization makes the approximation at most one output code value.
const transfer_low: u32 = 0x3780;
const transfer_high: u32 = 0x4280;
const transfer = blk: {
    @setEvalBranchQuota(50_000);
    var table: [transfer_high - transfer_low]u16 = undefined;
    for (&table, 0..) |*entry, i| {
        const value: f32 = @bitCast(((@as(u32, @intCast(i)) + transfer_low) << 16) | 0x8000);
        entry.* = (toneChannel(value, 31) << 11) | (toneChannel(value, 63) << 5) | toneChannel(value, 31);
    }
    break :blk table;
};
inline fn transferCode(value: f32) u16 {
    if (value <= 0) return 0;
    const bits: u32 = @bitCast(value);
    const bin = bits >> 16;
    if (bin < transfer_low) return 0;
    if (bin >= transfer_high) return 0xFFFF;
    return transfer[bin - transfer_low];
}
pub fn toneMap(linear: Vec) u16 {
    return (transferCode(linear.x) & 0xF800) | (transferCode(linear.y) & 0x07E0) | (transferCode(linear.z) & 0x001F);
}

pub const Region = struct { x: u16, y: u16, width: u16, height: u16 };
pub const Bucket = struct {
    region: Region,
    pixels: [bucket_size * bucket_size]u16 = @splat(0),
    samples: u32,
    completed_buckets: u32,
    total_buckets: u32,
    counters: Counters,
};

test "bounded Cornell planes, light and rotated boxes return nearest oriented hits" {
    const upper: Vec = .{ .y = 1.6, .z = 1 };
    const left = intersect(.{ .origin = upper, .direction = .{ .x = -1 } }).?;
    const right = intersect(.{ .origin = upper, .direction = .{ .x = 1 } }).?;
    try std.testing.expectEqual(red, left.albedo);
    try std.testing.expectEqual(green, right.albedo);
    try std.testing.expectEqual(@as(f32, 1), left.normal.x);
    try std.testing.expectEqual(@as(f32, -1), right.normal.x);
    try std.testing.expect(intersect(.{ .origin = upper, .direction = .{ .y = 1 } }).?.emitter);
    try std.testing.expect(!intersect(.{ .origin = .{ .x = 0.8, .y = 1.6, .z = 1 }, .direction = .{ .y = 1 } }).?.emitter);
    try std.testing.expect(intersect(.{ .origin = .{ .y = 1.6, .z = 0.1 }, .direction = .{ .z = -1 } }) == null);
    const box = intersect(.{ .origin = .{ .x = -0.4, .y = 0.32, .z = -1 }, .direction = .{ .z = 1 } }).?;
    try std.testing.expect(box.distance < 2 and box.normal.z < -0.8);
    try std.testing.expectApproxEqAbs(@as(f32, 1), box.normal.dot(box.normal), 0.00001);
    const floor = intersect(.{ .origin = .{ .x = 0.8, .y = 0.5, .z = 0.2 }, .direction = .{ .y = -1 } }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), floor.distance, 0.00001);
    try std.testing.expectEqual(@as(f32, 1), floor.normal.y);
    try std.testing.expect(occluded(boxes[1].center, .{ .y = 2, .z = 1 }));
    try std.testing.expect(!occluded(.{ .x = 0.85, .y = epsilon, .z = 0.2 }, .{ .x = 0.3, .y = 2, .z = 1 }));
    try std.testing.expect(boxHit(.{ .origin = .{ .x = 2, .y = 0.32, .z = 0.7 }, .direction = .{ .y = 1 } }, boxes[0], 1) == null);
}

test "cosine sampler is normalized and agrees with its Lambertian PDF" {
    var rng = Rng.init(42);
    for ([_]Vec{ .{ .x = 1 }, .{ .y = -1 }, .{ .z = -1 }, boxes[0].world(.{ .x = 1 }) }) |normal| {
        var average: f32 = 0;
        for (0..8192) |_| {
            const sample = cosineHemisphere(normal, &rng);
            const cosine = normal.dot(sample.direction);
            try std.testing.expect(cosine >= 0);
            try std.testing.expectApproxEqAbs(@as(f32, 1), sample.direction.dot(sample.direction), 0.00001);
            try std.testing.expectApproxEqAbs(cosine * inv_pi, sample.pdf, 0.000001);
            average += cosine / 8192.0;
        }
        try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), average, 0.015);
    }
}

test "direct and indirect light are finite and preserve colored diffuse walls" {
    var rng = Rng.init(123);
    var red_sum: Vec = .{};
    var green_sum: Vec = .{};
    var counts: Counters = .{};
    for (0..4096) |_| {
        const r = radiance(.{ .origin = .{ .y = 1.6, .z = 1 }, .direction = .{ .x = -1 } }, &rng, &counts);
        const g = radiance(.{ .origin = .{ .y = 1.6, .z = 1 }, .direction = .{ .x = 1 } }, &rng, &counts);
        inline for (0..3) |axis| {
            try std.testing.expect(std.math.isFinite(r.component(axis)) and r.component(axis) >= 0);
            try std.testing.expect(std.math.isFinite(g.component(axis)) and g.component(axis) >= 0);
        }
        red_sum = red_sum.add(r);
        green_sum = green_sum.add(g);
    }
    try std.testing.expect(red_sum.x > 5 * red_sum.y);
    try std.testing.expect(green_sum.y > 3 * green_sum.x);
    try std.testing.expect(counts.shadow_rays > counts.paths);
    try std.testing.expect(counts.rays <= max_bounces * counts.paths);
    var direct_counts: Counters = .{};
    const direct = radiance(.{ .origin = .{ .y = 1.6, .z = 1 }, .direction = .{ .y = 1 } }, &rng, &direct_counts);
    try std.testing.expectEqual(emission, direct);
}

test "ragged buckets cover every pixel exactly once and restart resumes deterministically" {
    var engine = try Engine.init(std.testing.allocator, 19, false, 7);
    defer engine.deinit();
    var reference = try Engine.init(std.testing.allocator, 19, false, 7);
    defer reference.deinit();
    var visited: [19 * 19]u8 = @splat(0);
    const total = engine.bucketCount();
    for (0..total) |i| {
        const tile = engine.renderNext().?;
        const expected = reference.renderNext().?;
        try std.testing.expectEqual(expected, tile);
        try std.testing.expectEqual(@as(u32, 1), tile.samples);
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), tile.completed_buckets);
        for (0..tile.region.height) |dy| {
            for (0..tile.region.width) |dx| visited[(@as(usize, tile.region.y) + dy) * 19 + tile.region.x + dx] += 1;
        }
    }
    for (visited) |count| try std.testing.expectEqual(@as(u8, 1), count);
    try std.testing.expectEqual(@as(u32, 1), engine.samples);
    const first = engine.renderNext().?;
    _ = reference.renderNext();
    for (0..total * 2 - 1) |_| try std.testing.expectEqual(reference.renderNext().?, engine.renderNext().?);
    engine.reset(7);
    reference.reset(7);
    for (0..total) |_| try std.testing.expectEqual(reference.renderNext().?, engine.renderNext().?);
    try std.testing.expectEqual(first.samples, @as(u32, 2));
    try std.testing.expectError(error.InvalidResolution, Engine.init(std.testing.allocator, 467, false, 0));
}

test "progressive linear accumulation reduces error before tone mapping" {
    var engine = try Engine.init(std.testing.allocator, 16, false, 42);
    defer engine.deinit();
    var one: [16 * 16]Vec = undefined;
    var sixteen: [16 * 16]Vec = undefined;
    while (engine.samples < 256) {
        _ = engine.renderNext();
        if (engine.cursor == 0 and engine.samples == 1) @memcpy(&one, engine.sum);
        if (engine.cursor == 0 and engine.samples == 16) {
            for (engine.sum, &sixteen) |sum, *dest| dest.* = sum.scale(1.0 / 16.0);
        }
    }
    var error_one: f32 = 0;
    var error_sixteen: f32 = 0;
    for (engine.sum, one, sixteen) |sum, low, medium| {
        const expected = sum.scale(1.0 / 256.0);
        const dl = low.sub(expected);
        const dm = medium.sub(expected);
        error_one += dl.dot(dl);
        error_sixteen += dm.dot(dm);
        try std.testing.expect(std.math.isFinite(sum.x) and std.math.isFinite(sum.y) and std.math.isFinite(sum.z));
    }
    try std.testing.expect(error_one > 0.01);
    try std.testing.expect(error_sixteen < 0.40 * error_one);
    try std.testing.expectEqual(@as(u16, 0), toneMap(.{}));
}

test "circular tracing skips invisible corner buckets" {
    var engine = try Engine.init(std.testing.allocator, 233, true, 1);
    defer engine.deinit();
    const corner = engine.renderNext().?;
    try std.testing.expectEqual(@as(u32, 0), corner.counters.paths);
    for (corner.pixels) |color| try std.testing.expectEqual(@as(u16, 0), color);
}

test "tone transfer is monotone and stays within one RGB565 code of the float reference" {
    var previous: u16 = 0;
    for (0..65_537) |i| {
        const value = @as(f32, @floatFromInt(i)) / 1024.0;
        const output = transferCode(value);
        try std.testing.expect(output >= previous);
        inline for ([_]u5{ 0, 5, 11 }, [_]u16{ 31, 63, 31 }) |shift, mask| {
            const actual: i32 = (output >> shift) & mask;
            const expected: i32 = toneChannel(value, @floatFromInt(mask));
            try std.testing.expect(@abs(actual - expected) <= 1);
        }
        previous = output;
    }
    try std.testing.expectEqual(@as(u16, 0xFFFF), transferCode(1_000_000));
    try std.testing.expectEqual(@as(u16, 0), transferCode(-1));
}

pub const Engine = struct {
    allocator: std.mem.Allocator,
    sum: []align(16) Vec,
    size: u16,
    circular: bool,
    seed: u32,
    samples: u32 = 0,
    cursor: u32 = 0,
    pub fn init(allocator: std.mem.Allocator, size: u16, circular: bool, seed: u32) !Engine {
        if (size < 8 or size > 466) return error.InvalidResolution;
        const sum = try allocator.alignedAlloc(Vec, .@"16", @as(usize, size) * size);
        @memset(sum, .{});
        return .{ .allocator = allocator, .sum = sum, .size = size, .circular = circular, .seed = seed };
    }
    pub fn deinit(self: *Engine) void {
        self.allocator.free(self.sum);
    }
    pub fn reset(self: *Engine, seed: u32) void {
        @memset(self.sum, .{});
        self.samples = 0;
        self.cursor = 0;
        self.seed = seed;
    }
    pub fn memoryBytes(self: Engine) usize {
        return self.sum.len * @sizeOf(Vec);
    }
    pub fn bucketCount(self: Engine) u32 {
        const edge: u32 = (@as(u32, self.size) + bucket_size - 1) / bucket_size;
        return edge * edge;
    }
    pub fn renderNext(self: *Engine) ?Bucket {
        if (self.samples >= max_samples) return null;
        const columns = (@as(u32, self.size) + bucket_size - 1) / bucket_size;
        const x: u16 = @intCast((self.cursor % columns) * bucket_size);
        const y: u16 = @intCast((self.cursor / columns) * bucket_size);
        var result: Bucket = .{
            .region = .{ .x = x, .y = y, .width = @min(bucket_size, self.size - x), .height = @min(bucket_size, self.size - y) },
            .samples = self.samples + 1,
            .completed_buckets = self.cursor + 1,
            .total_buckets = self.bucketCount(),
            .counters = .{},
        };
        const inverse_samples = 1.0 / @as(f32, @floatFromInt(result.samples));
        const inverse_size = 1.0 / @as(f32, @floatFromInt(self.size));
        for (0..result.region.height) |dy| {
            for (0..result.region.width) |dx| {
                const px: usize = x + dx;
                const py: usize = y + dy;
                const index = py * self.size + px;
                if (self.circular) {
                    const cx = 2 * @as(i32, @intCast(px)) + 1 - @as(i32, self.size);
                    const cy = 2 * @as(i32, @intCast(py)) + 1 - @as(i32, self.size);
                    if (cx * cx + cy * cy > @as(i32, self.size) * self.size) continue;
                }
                var rng = Rng.init(@as(u32, @intCast(index)) ^ self.seed ^ (result.samples *% 0x9E3779B9));
                const film_x = (2 * (@as(f32, @floatFromInt(px)) + rng.uniform()) * inverse_size - 1) * 0.34;
                const film_y = (1 - 2 * (@as(f32, @floatFromInt(py)) + rng.uniform()) * inverse_size) * 0.34;
                // Primary rays need not be unit length: emission MIS is used
                // only after the first, normalized cosine-sampled bounce.
                const ray: Ray = .{ .origin = .{ .y = 1.02, .z = -3.2 }, .direction = .{ .x = film_x, .y = film_y, .z = 1 } };
                self.sum[index] = self.sum[index].add(radiance(ray, &rng, &result.counters));
                result.pixels[dy * bucket_size + dx] = toneMap(self.sum[index].scale(inverse_samples));
            }
        }
        self.cursor += 1;
        if (self.cursor == result.total_buckets) {
            self.cursor = 0;
            self.samples += 1;
        }
        return result;
    }
};
