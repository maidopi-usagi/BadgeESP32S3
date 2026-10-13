const std = @import("std");
pub const sample_rate = 22050;
pub const total_samples = sample_rate * 32;
pub const peak_limit = 6000;
const beat_samples = 11025;
const chord_notes = [4][3]u8{ .{ 50, 53, 57 }, .{ 46, 50, 53 }, .{ 53, 57, 60 }, .{ 48, 52, 55 } };
const melody = [16]u8{ 74, 77, 81, 77, 72, 74, 77, 81, 79, 77, 74, 72, 69, 72, 74, 77 };
const increments = blk: {
    @setEvalBranchQuota(20_000);
    var values: [96]u32 = undefined;
    for (&values, 0..) |*v, i| v.* = @intFromFloat(440.0 * std.math.pow(f64, 2, (@as(f64, @floatFromInt(i)) - 69) / 12) * (4294967296.0 / @as(f64, sample_rate)));
    break :blk values;
};
const sine = blk: {
    var values: [256]i16 = undefined;
    for (&values, 0..) |*v, i| v.* = @intFromFloat(@sin(@as(f64, @floatFromInt(i)) * (2 * std.math.pi / 256.0)) * 32767);
    break :blk values;
};
fn wave(position: u32, note: u8) i32 {
    const phase: u32 = @truncate(@as(u64, position) * increments[note]);
    return sine[phase >> 24];
}
pub fn sample(position: u32) i16 {
    if (position >= total_samples) return 0;
    const beat = position / beat_samples;
    const in_beat = position % beat_samples;
    const eighth = position * 2 / beat_samples;
    const in_eighth = position - eighth * beat_samples / 2;
    const distance: u32 = beat_samples / 2 - @min(in_eighth, beat_samples / 2);
    const envelope: i32 = @intCast(@as(u32, distance) * 1024 / (beat_samples / 2));
    const chord = chord_notes[(beat / 8) % 4];
    var value = @divTrunc(wave(position, melody[eighth % 16]) * envelope, 32768 / 2);
    value += @divTrunc(wave(position, chord[0] - 12), 32);
    value += @divTrunc(wave(position, chord[1]) + wave(position, chord[2]), 64);
    if (in_beat < 3300) {
        const env: i32 = @intCast((3300 - in_beat) * 1600 / 3300);
        value += @divTrunc(wave(in_beat, 35) * env, 32768);
    }
    var noise = position *% 0x9E3779B9;
    noise ^= noise >> 16;
    noise *%= 0x85EBCA6B;
    const white: i32 = @as(i32, @intCast(noise & 65535)) - 32768;
    if (beat % 2 == 1 and in_beat < 1900) value += @divTrunc(white * @as(i32, @intCast((1900 - in_beat) * 1000 / 1900)), 32768);
    if (in_eighth < 700) value += @divTrunc(white * @as(i32, @intCast((700 - in_eighth) * 350 / 700)), 32768);
    const fade: i32 = @intCast(@min(2048, @min(position, total_samples - position)));
    const faded: i64 = @divTrunc(@as(i64, value) * @as(i64, fade), 2048);
    return @intCast(std.math.clamp(faded, @as(i64, -peak_limit), @as(i64, peak_limit)));
}
pub fn fill(start: u32, samples: []i16) void {
    for (samples, 0..) |*s, i| s.* = sample(start + @as(u32, @intCast(i)));
}
test "track is bounded, audible and exactly seekable across block boundaries" {
    var energy: u64 = 0;
    var sum: i64 = 0;
    for (0..total_samples) |i| {
        const v = sample(@intCast(i));
        try std.testing.expect(@abs(v) <= peak_limit);
        energy += @as(u64, @intCast(@as(i32, v) * v));
        sum += v;
    }
    try std.testing.expect(energy / total_samples > 100_000);
    try std.testing.expect(@abs(@divTrunc(sum, total_samples)) < 50);
    var block: [512]i16 = undefined;
    fill(137_421, &block);
    for (block, 0..) |v, i| try std.testing.expectEqual(sample(137_421 + @as(u32, @intCast(i))), v);
    try std.testing.expectEqual(@as(i16, 0), sample(total_samples));
}
