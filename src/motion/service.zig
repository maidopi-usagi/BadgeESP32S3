const std = @import("std");
const idf = @import("esp_idf");
const imu = @import("board").Imu;
const Demo = @import("../demo.zig").Demo;
const parallax = @import("parallax.zig");
const log = std.log.scoped(idf.log.default_log_scope);
/// Screen axes, g and radians/second; original sample time prevents double counting.
pub const Reading = struct { accel: [3]f32 = @splat(0), gyro: [3]f32 = @splat(0), time_ms: u64 = 0 };
const Snapshot = struct { generation: u32 = 0, offset: parallax.Offset = .{}, reading: Reading = .{} };
var queue: idf.rtos.QueueHandle = null;
var latest_snapshot: Snapshot = .{}; // Accessed by LVGL only.
const Command = struct { mode: imu.Mode, generation: u32, pause_ticket: u32 };
var generation: u32 = 0; // UI-owned; reject pre-transition samples.
var commands: idf.rtos.QueueHandle = null;
var pause: @import("../power/pause.zig").Latch = .{};
pub fn isPaused() bool {
    return pause.quiet();
}
pub fn setPage(page: Demo) void {
    setMode(switch (page) {
        .fumo, .dice => .six_axis,
        .sandbox, .fluid, .physics => .accelerometer,
        .cornell, .doom, .rhythm => .off,
    });
}
pub fn pauseForSleep() void {
    setMode(.off);
}
fn setMode(mode: imu.Mode) void {
    if (commands == null) return;
    if (mode == .off) pause.request();
    generation +%= 1;
    const command: Command = .{ .mode = mode, .generation = generation, .pause_ticket = pause.ticket };
    idf.rtos.Queue.overwrite(commands, &command);
    latest_snapshot = .{};
}

// Called during UI initialization while its display mutex is held.
pub fn start(page: Demo) !void {
    queue = try idf.rtos.Queue.create(1, @sizeOf(Snapshot));
    errdefer {
        idf.rtos.Queue.delete(queue);
        queue = null;
    }
    commands = try idf.rtos.Queue.create(1, @sizeOf(Command));
    errdefer {
        idf.rtos.Queue.delete(commands);
        commands = null;
    }
    setPage(page);
    // Short, blocking reads must run above LVGL (6), even during full redraws.
    _ = idf.rtos.Task.createPinnedToCore(poll, "fumo_motion", 4096, null, 7, 1) catch |err| {
        pause.stop();
        return err;
    };
}

pub fn latest(now_ms: u64) parallax.Offset {
    return if (fresh(now_ms)) latest_snapshot.offset else .{};
}
pub fn acceleration(now_ms: u64) ?[3]f32 {
    return if (fresh(now_ms)) latest_snapshot.reading.accel else null;
}
pub fn reading(now_ms: u64) ?Reading {
    return if (fresh(now_ms)) latest_snapshot.reading else null;
}
fn fresh(now_ms: u64) bool {
    if (queue == null) return false;
    _ = idf.rtos.Queue.receive(queue, &latest_snapshot, 0);
    const sampled_ms = latest_snapshot.reading.time_ms;
    return latest_snapshot.generation == generation and sampled_ms != 0 and now_ms >= sampled_ms and now_ms - sampled_ms <= 250;
}

fn poll(_: ?*anyopaque) callconv(.c) void {
    run() catch |err| log.err("Motion stopped: {s}; keeping touch/auto rotation", .{@errorName(err)});
    imu.close();
    const reset: Snapshot = .{};
    idf.rtos.Queue.overwrite(queue, &reset);
    pause.stop();
    idf.rtos.Task.delete(null);
}

fn run() !void {
    const info = try imu.open(idf.rtos.Task.delayMs);
    log.info("QMI8658 ready: addr=0x6b, WHO=0x{x}, revision=0x{x}, +/-4g, +/-256dps; page-controlled off/accel/six-axis", .{ info.id, info.revision });
    var filter: parallax.Filter = .{};
    var errors: u8 = 0;
    var count: u32 = 0;
    var last_log: u64 = 0;
    var last_fresh: i64 = idf.sys.esp_timer_get_time();
    var mode: imu.Mode = .off;
    var sample_generation: u32 = 0;
    var settled_at: i64 = 0;
    while (true) {
        var command: Command = undefined;
        if (idf.rtos.Queue.receive(commands, &command, if (mode != .off) idf.rtos.msToTicks(20) else idf.rtos.portMAX_DELAY)) {
            sample_generation = command.generation;
            if (command.mode != mode) {
                try imu.setMode(command.mode);
                mode = command.mode;
                filter = .{};
                errors = 0;
                last_fresh = idf.sys.esp_timer_get_time();
                settled_at = last_fresh + @as(i64, if (mode == .six_axis) 100_000 else 40_000);
                last_log = @intCast(@divTrunc(last_fresh, 1000));
                count = 0;
            }
            log.info("Motion mode={s}, generation={d}; registers verified", .{ @tagName(mode), sample_generation });
            if (mode == .off) {
                const reset: Snapshot = .{ .generation = sample_generation };
                idf.rtos.Queue.overwrite(queue, &reset);
                pause.ack(command.pause_ticket);
            }
        }
        if (mode == .off or idf.sys.esp_timer_get_time() < settled_at) continue;
        const raw = imu.sample() catch |err| {
            errors += 1;
            if (errors == 1) log.warn("Motion read failed: {s}", .{@errorName(err)});
            if (errors >= 10) return err;
            continue;
        } orelse {
            if (idf.sys.esp_timer_get_time() - last_fresh > 1_000_000) return error.ImuDataTimeout;
            continue;
        };
        errors = 0;
        const now_ms: u64 = @intCast(@divTrunc(idf.sys.esp_timer_get_time(), 1000));
        last_fresh = idf.sys.esp_timer_get_time();
        var sample: parallax.Sample = undefined;
        for (0..3) |i| {
            sample.accel[i] = @as(f32, @floatFromInt(raw.accel[i])) / imu.accel_lsb_per_g;
            sample.gyro[i] = @as(f32, @floatFromInt(raw.gyro[i])) * ((std.math.pi / 180.0) / imu.gyro_lsb_per_dps);
        }
        sample.accel = imu.screenAxes(sample.accel);
        sample.gyro = imu.screenAxes(sample.gyro);
        const calibrated = filter.calibrated;
        const recenters = filter.recenters;
        if (mode == .six_axis) filter.update(sample, now_ms);
        if (!calibrated and filter.calibrated) log.info("Motion calibrated: neutral captured, gyro bias removed, max parallax={d} deg", .{parallax.max_degrees});
        if (recenters != filter.recenters) log.info("Motion recentered: held still for {d} ms, neutral updated for current posture", .{parallax.recenter_after_ms});
        const snapshot: Snapshot = .{ .generation = sample_generation, .offset = filter.offset, .reading = .{ .accel = sample.accel, .gyro = sample.gyro, .time_ms = now_ms } };
        idf.rtos.Queue.overwrite(queue, &snapshot);
        count += 1;
        if (now_ms - last_log >= 5000) {
            log.info("Motion: {d} samples, mode={s}, calibrated={}; parallax yaw/pitch={d}/{d} mdeg; acc={d},{d},{d} mg, gyro={d},{d},{d} mdps", .{
                count,                                          @tagName(mode),                                 filter.calibrated,                              milliDegrees(filter.offset.yaw),              milliDegrees(filter.offset.pitch),
                @divTrunc(@as(i32, raw.accel[0]) * 1000, 8192), @divTrunc(@as(i32, raw.accel[1]) * 1000, 8192), @divTrunc(@as(i32, raw.accel[2]) * 1000, 8192), @divTrunc(@as(i32, raw.gyro[0]) * 1000, 128), @divTrunc(@as(i32, raw.gyro[1]) * 1000, 128),
                @divTrunc(@as(i32, raw.gyro[2]) * 1000, 128),
            });
            last_log = now_ms;
        }
    }
}

fn milliDegrees(angle: f32) i32 {
    return @intFromFloat(angle * (180000.0 / std.math.pi));
}
