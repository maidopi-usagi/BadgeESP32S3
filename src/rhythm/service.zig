//! Codec and sample clock belong to one persistent audio worker, not LVGL.
const std = @import("std");
const idf = @import("esp_idf");
const audio = @import("board").Audio;
const music = @import("music.zig");
const log = std.log.scoped(idf.log.default_log_scope);
const Command = struct { active: bool, serial: u32, position_ms: u32, pause_ticket: u32 = 0 };
var pause: @import("../power/pause.zig").Latch = .{};
pub fn isPaused() bool {
    return pause.quiet();
}
pub const Snapshot = struct { serial: u32 = 0, status: enum { playing, done, failed } = .playing, position_ms: u32 = 0, stamp_ms: u64 = 0 };
var commands: idf.rtos.QueueHandle = null;
var snapshots: idf.rtos.QueueHandle = null;
var serial: u32 = 0; // LVGL-owned, filters stale start/pause acknowledgments.
var latest: Snapshot = .{};
// Fixed BSP/IDF I2S_CHANNEL_DEFAULT_CONFIG: 6 descriptors x 240 samples.
const dma_samples = 6 * 240;
pub fn request(active: bool, position_ms: u32) !void {
    if (commands == null and !active) return;
    if (commands == null) {
        commands = try idf.rtos.Queue.create(1, @sizeOf(Command));
        errdefer {
            idf.rtos.Queue.delete(commands);
            commands = null;
        }
        snapshots = try idf.rtos.Queue.create(1, @sizeOf(Snapshot));
        errdefer {
            idf.rtos.Queue.delete(snapshots);
            snapshots = null;
        }
        _ = try idf.rtos.Task.createPinnedToCore(worker, "orbit_audio", 6144, null, 8, 1);
    }
    serial +%= 1;
    if (!active) pause.request();
    const command: Command = .{ .active = active, .serial = serial, .position_ms = position_ms, .pause_ticket = pause.ticket };
    idf.rtos.Queue.overwrite(commands, &command);
}
pub fn poll(now: u64) ?Snapshot {
    if (snapshots == null) return null;
    _ = idf.rtos.Queue.receive(snapshots, &latest, 0);
    if (latest.serial != serial or latest.stamp_ms == 0) return null;
    var result = latest;
    if (result.status == .playing) result.position_ms = @min(32_000, result.position_ms + @as(u32, @intCast(@min(30, now -| result.stamp_ms))));
    return result;
}
fn publish(command: Command, status: @FieldType(Snapshot, "status"), position_ms: u32) void {
    const snapshot: Snapshot = .{ .serial = command.serial, .status = status, .position_ms = position_ms, .stamp_ms = @intCast(@divTrunc(idf.sys.esp_timer_get_time(), 1000)) };
    idf.rtos.Queue.overwrite(snapshots, &snapshot);
}
fn worker(_: ?*anyopaque) callconv(.c) void {
    var command: Command = .{ .active = false, .serial = 0, .position_ms = 0 };
    var opened = false;
    var cursor: u32 = 0;
    var block: [512]i16 = undefined;
    var stats_start: i64 = 0;
    var blocks: u32 = 0;
    var synth_us: i64 = 0;
    var max_us: i64 = 0;
    while (true) {
        if (!command.active) pause.ack(command.pause_ticket);
        var next: Command = undefined;
        if (idf.rtos.Queue.receive(commands, &next, if (command.active) 0 else idf.rtos.portMAX_DELAY)) {
            if (opened) {
                audio.close();
                opened = false;
            }
            command = next;
            if (!command.active) continue;
            audio.open(music.sample_rate, 100) catch |err| {
                audio.close();
                publish(command, .failed, command.position_ms);
                command.active = false;
                log.err("Orbit audio open failed: {s}", .{@errorName(err)});
                continue;
            };
            opened = true;
            cursor = command.position_ms * music.sample_rate / 1000;
            stats_start = idf.sys.esp_timer_get_time();
            blocks = 0;
            synth_us = 0;
            max_us = 0;
            publish(command, .playing, command.position_ms);
            log.info("Orbit audio: 120 BPM, 32s original track, resume={d} ms, DMA latency estimate=65 ms", .{command.position_ms});
        }
        if (!command.active) continue;
        const start = idf.sys.esp_timer_get_time();
        music.fill(cursor, &block);
        const elapsed = idf.sys.esp_timer_get_time() - start;
        synth_us += elapsed;
        max_us = @max(max_us, elapsed);
        blocks += 1;
        audio.write(&block) catch |err| {
            audio.close();
            opened = false;
            publish(command, .failed, command.position_ms);
            command.active = false;
            log.err("Orbit audio write failed: {s}", .{@errorName(err)});
            continue;
        };
        cursor += block.len;
        const played_ms = @min(32_000, (cursor -| dma_samples) * 1000 / music.sample_rate);
        publish(command, if (played_ms == 32_000) .done else .playing, @max(command.position_ms, played_ms));
        const now = idf.sys.esp_timer_get_time();
        if (now - stats_start >= 2_000_000) {
            log.info("Orbit PCM: position={d} ms, blocks={d}, avg/max synth={d}/{d} us, stack free={d}", .{ played_ms, blocks, @divTrunc(synth_us, blocks), max_us, idf.rtos.Task.getStackHighWaterMark(null) });
            stats_start = now;
            blocks = 0;
            synth_us = 0;
            max_us = 0;
        }
        if (played_ms == 32_000) {
            audio.close();
            opened = false;
            command.active = false;
        }
    }
}
