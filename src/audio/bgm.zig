const std = @import("std");
const idf = @import("esp_idf");
const audio = @import("board").Audio;
const music = @import("synth.zig");
const log = std.log.scoped(idf.log.default_log_scope);
pub const autoplay_enabled = false;
const playback_volume = 100;
var synth: music.Synth = .{};

pub fn start() !void {
    // Feed DMA before LVGL (priority 6); blocking I2S writes release the CPU.
    _ = try idf.rtos.Task.createPinnedToCore(play, "retro_bgm", 8192, null, 8, 1);
}

fn play(_: ?*anyopaque) callconv(.c) void {
    run() catch |err| {
        audio.close();
        log.err("BGM stopped: {s}", .{@errorName(err)});
    };
    idf.rtos.Task.delete(null);
}

fn run() !void {
    try audio.open(music.sample_rate, playback_volume);
    defer audio.close();
    const status = try audio.status();
    if (status.volume != playback_volume or status.mute & 0x60 != 0) return error.SpeakerSettingMismatch;
    log.info("ES8311 readback: volume={d}, mute=0x{x}, DAC gain=0x{x}, I2S format=0x{x}", .{ status.volume, status.mute, status.gain, status.format });
    log.info("Retro BGM started: Zig synth, {d} Hz mono, 110 BPM, volume={d}/100, PCM peak<={d}, test={d}s", .{ music.sample_rate, playback_volume, music.peak_limit, music.duration_seconds });
    var samples: [512]i16 = undefined;
    var generation_us: i64 = 0;
    var max_generation_us: i64 = 0;
    var late_blocks: u32 = 0;
    var blocks: u32 = 0;
    const playback_start = idf.sys.esp_timer_get_time();
    while (synth.position < music.total_samples) {
        const count = @min(samples.len, music.total_samples - synth.position);
        const start_us = idf.sys.esp_timer_get_time();
        synth.fill(samples[0..count]);
        const elapsed = idf.sys.esp_timer_get_time() - start_us;
        generation_us += elapsed;
        max_generation_us = @max(max_generation_us, elapsed);
        if (elapsed > @divTrunc(@as(i64, @intCast(count)) * 1000000, music.sample_rate)) late_blocks += 1;
        try audio.write(samples[0..count]);
        blocks += 1;
    }
    @memset(&samples, 0);
    for (0..6) |_| try audio.write(&samples);
    log.info("Retro BGM finished: {d} blocks in {d} ms, synthesis avg/max={d}/{d} us, late={d}, stack free={d} bytes; fading to silence", .{ blocks, @divTrunc(idf.sys.esp_timer_get_time() - playback_start, 1000), @divTrunc(generation_us, blocks), max_generation_us, late_blocks, idf.rtos.Task.getStackHighWaterMark(null) });
}
