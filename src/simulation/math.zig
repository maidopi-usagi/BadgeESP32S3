const std = @import("std");

// Positive normal f32 inputs only. Newton refinements keep relative error
// below 6e-6 without Xtensa ROM division / sqrt calls in the hot loops.
pub inline fn reciprocal(x: f32) f32 {
    var r: f32 = @bitCast(@as(u32, 0x7EF311C3) - @as(u32, @bitCast(x)));
    r *= 2 - x * r;
    r *= 2 - x * r;
    r *= 2 - x * r;
    return r;
}
pub inline fn inverseSqrt(x: f32) f32 {
    var r: f32 = @bitCast(@as(u32, 0x5F3759DF) - (@as(u32, @bitCast(x)) >> 1));
    r *= 1.5 - 0.5 * x * r * r;
    r *= 1.5 - 0.5 * x * r * r;
    return r;
}

pub const Vec = struct {
    x: f32 = 0,
    y: f32 = 0,
    pub inline fn add(a: Vec, b: Vec) Vec {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub inline fn sub(a: Vec, b: Vec) Vec {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub inline fn scale(a: Vec, s: f32) Vec {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub inline fn dot(a: Vec, b: Vec) f32 {
        return a.x * b.x + a.y * b.y;
    }
    pub inline fn length2(a: Vec) f32 {
        return dot(a, a);
    }
};

test "reciprocal and inverse sqrt stay within six ppm across the solver domain" {
    var seed: u32 = 0x913724;
    for (0..8192) |_| {
        seed = seed *% 1664525 +% 1013904223;
        const bits = @as(u32, 0x38D1B718) + seed % (0x47C35000 - 0x38D1B718);
        const x: f32 = @bitCast(bits);
        try std.testing.expectApproxEqAbs(@as(f32, 1), x * reciprocal(x), 0.000006);
        try std.testing.expectApproxEqAbs(@as(f32, 1), @sqrt(x) * inverseSqrt(x), 0.000006);
    }
}
