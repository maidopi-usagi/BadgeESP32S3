const std = @import("std");
pub const sample_rate = 22050;
pub const duration_seconds = 30;
pub const total_samples = sample_rate * duration_seconds;
pub const peak_limit = 6000;
const step_samples = sample_rate * 60 / (110 * 4);
const bar_samples = step_samples * 16;
const fade_samples = sample_rate * 4 / 5;
const chords = [4][4]u8{ .{ 50, 53, 57, 60 }, .{ 46, 50, 53, 57 }, .{ 53, 57, 60, 64 }, .{ 48, 52, 55, 58 } };
const arp_order = [_]u8{ 0, 2, 3, 1, 2, 1, 3, 2 };
const sine = blk: {
    var table: [256]i16 = undefined;
    for (&table, 0..) |*value, i| value.* = @intFromFloat(@sin(@as(f64, @floatFromInt(i)) * (2 * std.math.pi / 256.0)) * 32767);
    break :blk table;
};
const note_steps = blk: {
    @setEvalBranchQuota(20000);
    var table: [96]u32 = undefined;
    for (&table, 0..) |*value, i| {
        const hz = 440.0 * std.math.pow(f64, 2, (@as(f64, @floatFromInt(i)) - 69) / 12);
        value.* = @intFromFloat(hz * (4294967296.0 / @as(f64, sample_rate)) + 0.5);
    }
    break :blk table;
};

fn wave(phase: u32) i32 {
    return sine[phase >> 24];
}

fn triangle(phase: u32) i32 {
    const position: i32 = @intCast(phase >> 16);
    return if (position < 32768) position * 2 - 32768 else 98303 - position * 2;
}

fn level(value: i32, gain: i32) i32 {
    return @divTrunc(value * gain, 32768);
}

fn decay(position: u32, comptime length: u32) i32 {
    if (position >= length) return 0;
    const table = comptime blk: {
        @setEvalBranchQuota(10000);
        var values: [(length + 15) / 16]u16 = undefined;
        for (&values, 0..) |*value, i| {
            const envelope: i32 = @intCast((length - i * 16) * 32767 / length);
            value.* = @intCast(level(envelope, envelope));
        }
        break :blk values;
    };
    return table[position >> 4];
}

fn ramp(position: u32, comptime length: u32) i32 {
    if (position >= length) return 32767;
    const table = comptime blk: {
        @setEvalBranchQuota(10000);
        var values: [(length + 15) / 16]u16 = undefined;
        for (&values, 0..) |*value, i| value.* = @intCast(i * 16 * 32767 / length);
        break :blk values;
    };
    return table[position >> 4];
}

const kick_length = sample_rate / 6;
const kick_steps = blk: {
    var values: [(kick_length + 15) / 16]u32 = undefined;
    for (&values, 0..) |*value, i| {
        const hz = 58 + (kick_length - i * 16) * 75 / kick_length;
        value.* = @intCast(@as(u64, hz) * 4294967296 / sample_rate);
    }
    break :blk values;
};

pub const Synth = struct {
    position: u32 = 0,
    step: u32 = 0,
    in_step: u32 = 0,
    in_beat: u32 = 0,
    chord_pos: u32 = 0,
    pad_phase: [4]u32 = @splat(0),
    pad_step: [4]u32 = @splat(0),
    bass_phase: u32 = 0,
    bass_step: u32 = 0,
    arp_phase: u32 = 0,
    arp_step: u32 = 0,
    kick_phase: u32 = 0,
    snare_phase: u32 = 0,
    noise: u32 = 0x79A3B52D,
    previous_noise: i32 = 0,
    delay: [2048]i16 = @splat(0),
    delay_index: usize = 0,
    dc_input: i32 = 0,
    dc_output: i32 = 0,

    pub fn fill(self: *Synth, output: []i16) void {
        for (output) |*sample| sample.* = self.next();
    }

    fn next(self: *Synth) i16 {
        if (self.position >= total_samples) return 0;
        const in_step = self.in_step;
        const in_beat = self.in_beat;
        if (in_step == 0) {
            const chord = chords[(self.step >> 5) & 3];
            for (&self.pad_step, chord, 0..) |*increment, note, i| {
                increment.* = note_steps[note] + @as(u32, @intCast(i)) * 11000;
            }
            self.bass_step = note_steps[chord[0]];
            self.arp_step = note_steps[chord[arp_order[self.step & 7]] + 12];
        }
        const chord_ramp = @min(self.chord_pos, bar_samples * 2 - self.chord_pos);
        const pad_envelope = ramp(chord_ramp, step_samples * 2);
        var mixed: i32 = 0;
        for (&self.pad_phase, self.pad_step) |*phase, increment| {
            phase.* +%= increment;
            mixed += level(level(wave(phase.*) + @divTrunc(triangle(phase.*), 3), 470), pad_envelope);
        }
        self.bass_phase +%= self.bass_step;
        const bass_attack: i32 = if (in_beat >= 100) 32767 else @intCast(in_beat * 32767 / 100);
        mixed += level(level(level(triangle(self.bass_phase), 1350), decay(in_beat, step_samples * 3)), bass_attack);
        self.arp_phase +%= self.arp_step;
        const arp_attack: i32 = if (in_step >= 80) 32767 else @intCast(in_step * 32767 / 80);
        mixed += level(level(level(@divTrunc(wave(self.arp_phase) + triangle(self.arp_phase), 2), 1250), decay(in_step, step_samples)), arp_attack);

        if (in_beat < kick_length) {
            self.kick_phase +%= kick_steps[in_beat >> 4];
            mixed += level(level(wave(self.kick_phase), 1550), decay(in_beat, kick_length));
        }
        self.noise ^= self.noise << 13;
        self.noise ^= self.noise >> 17;
        self.noise ^= self.noise << 5;
        const noise_value = @as(i32, @intCast(self.noise >> 16)) - 32768;
        const high_noise = @divTrunc(noise_value - self.previous_noise, 2);
        self.previous_noise = noise_value;
        if (self.step & 4 != 0) {
            self.snare_phase +%= note_steps[54];
            const snare = @divTrunc(high_noise + wave(self.snare_phase), 2);
            mixed += level(level(snare, 1000), decay(in_beat, sample_rate / 8));
        }
        const in_hat = in_step + (self.step & 1) * step_samples;
        mixed += level(level(high_noise, 310), decay(in_hat, sample_rate / 35));

        const echo: i32 = self.delay[self.delay_index];
        self.delay[self.delay_index] = @intCast(std.math.clamp(mixed + @divTrunc(echo, 3), -12000, 12000));
        self.delay_index = (self.delay_index + 1) & (self.delay.len - 1);
        mixed += @divTrunc(echo, 5);
        const filtered = mixed - self.dc_input + level(self.dc_output, 32700);
        self.dc_input = mixed;
        self.dc_output = filtered;
        mixed = filtered;
        const fade_pos = @min(self.position, total_samples - 1 - self.position);
        const fade = ramp(fade_pos, fade_samples);
        self.position += 1;
        self.in_step += 1;
        if (self.in_step == step_samples) {
            self.in_step = 0;
            self.step += 1;
        }
        self.in_beat += 1;
        if (self.in_beat == step_samples * 4) self.in_beat = 0;
        self.chord_pos += 1;
        if (self.chord_pos == bar_samples * 2) self.chord_pos = 0;
        return @intCast(std.math.clamp(level(mixed, fade), -peak_limit, peak_limit));
    }
};

test "30-second synth is audible, bounded, faded, and ends in silence" {
    var synth: Synth = .{};
    var peak: u32 = 0;
    var energy: u64 = 0;
    var sum: i64 = 0;
    for (0..total_samples) |i| {
        const value: i32 = synth.next();
        const magnitude = @abs(value);
        peak = @max(peak, magnitude);
        try std.testing.expect(magnitude <= peak_limit);
        energy += @intCast(value * value);
        sum += value;
        if (i == 0 or i == total_samples - 1) try std.testing.expectEqual(@as(i32, 0), value);
    }
    try std.testing.expect(peak > 1500 and energy / total_samples > 100000);
    try std.testing.expect(@abs(@divTrunc(sum, total_samples)) < 40);
    try std.testing.expectEqual(@as(i16, 0), synth.next());
}
