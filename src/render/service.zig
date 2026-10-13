const std = @import("std");
const idf = @import("esp_idf");
const core = @import("pathtracer.zig");
const ui = @import("../ui/cornell.zig");
const pixel = @import("../ui/pixel_canvas.zig");
const log = std.log.scoped(idf.log.default_log_scope);
var pause: @import("../power/pause.zig").Latch = .{};
pub fn isPaused() bool {
    return pause.quiet();
}
const queue_depth = 8;
var control_queue: idf.rtos.QueueHandle = null;
var result_queue: idf.rtos.QueueHandle = null;
var initialized = false;
var view: ui.View = undefined; // LVGL-owned, including reset generations.
var heap = idf.heap.HeapCapsAllocator.init(.{ .spiram = true, .@"8bit" = true });

/// Called only by UI initialization or LVGL callbacks, inside their display lock.
pub fn setActive(active: bool) !void {
    if (!initialized and !active) return;
    if (!initialized) try start();
    if (!active) pause.request();
    var command = view.command(active);
    command.pause_ticket = pause.ticket;
    idf.rtos.Queue.overwrite(control_queue, &command);
}
fn start() !void {
    view = try ui.View.init(heap.allocator(), ui.resolution);
    errdefer view.deinit();
    control_queue = try idf.rtos.Queue.create(1, @sizeOf(ui.Command));
    errdefer idf.rtos.Queue.delete(control_queue);
    result_queue = try idf.rtos.Queue.create(queue_depth, @sizeOf(ui.Packet));
    errdefer idf.rtos.Queue.delete(result_queue);
    _ = try idf.rtos.Task.createPinnedToCore(worker, "cornell_trace", 6144, null, 2, 0);
    initialized = true;
}
pub fn restart() void {
    if (!initialized or view.failed) return;
    view.reset(idf.sys.esp_random());
    const command = view.command(true);
    idf.rtos.Queue.overwrite(control_queue, &command);
}
pub const Update = struct {
    regions: [queue_depth]core.Region = undefined,
    len: usize = 0,
    hud: bool = false,
    full: bool = false,
    pub fn slice(self: *const Update) []const core.Region {
        return self.regions[0..self.len];
    }
};
pub fn poll(now_ms: u64) Update {
    var update: Update = .{};
    if (!initialized) return update;
    for (0..queue_depth) |_| {
        var packet: ui.Packet = undefined;
        if (!idf.rtos.Queue.receive(result_queue, &packet, 0)) break;
        if (!view.accept(packet)) continue;
        if (packet.failed) {
            update.full = true;
        } else {
            update.regions[update.len] = packet.bucket.region;
            update.len += 1;
        }
    }
    update.hud = view.advanceHud(now_ms);
    return update;
}
pub fn paintFull(canvas: pixel.Canvas) void {
    if (initialized) view.paint(canvas) else ui.waiting(canvas);
}
pub fn paint(canvas: pixel.Canvas, update: Update) void {
    for (update.slice()) |region| view.paintRegion(canvas, region);
    view.overlay(canvas);
}

fn worker(_: ?*anyopaque) callconv(.c) void {
    var command: ui.Command = undefined;
    _ = idf.rtos.Queue.receive(control_queue, &command, idf.rtos.portMAX_DELAY);
    var engine = core.Engine.init(heap.allocator(), ui.resolution, true, command.seed) catch |err| {
        log.err("Cornell allocation failed: {s}; page switching remains available", .{@errorName(err)});
        const failed: ui.Packet = .{ .generation = command.generation, .failed = true, .bucket = undefined };
        _ = idf.rtos.Queue.send(result_queue, &failed, idf.rtos.portMAX_DELAY);
        pause.stop();
        idf.rtos.Task.delete(null);
        return;
    };
    log.info("Cornell tracer ready: {d}x{d}, {d}x display, {d}x{d} buckets, accumulation={d} bytes, cache={d} bytes, core=0", .{ ui.resolution, ui.resolution, ui.display_scale, core.bucket_size, core.bucket_size, engine.memoryBytes(), ui.resolution * ui.resolution * @sizeOf(u16) });
    var pending: ?ui.Packet = null;
    var last_log = idf.sys.esp_timer_get_time();
    var paths: u64 = 0;
    var rays: u64 = 0;
    var buckets: u32 = 0;
    var compute_us: i64 = 0;
    var peak_us: i64 = 0;
    var pass_start_us = last_log;
    var last_completed_sample: u32 = 0;
    var paused_at_us: ?i64 = if (command.active) null else last_log;
    while (true) {
        if (!command.active) pause.ack(command.pause_ticket);
        var next: ui.Command = undefined;
        if (idf.rtos.Queue.receive(control_queue, &next, if (command.active) 0 else idf.rtos.portMAX_DELAY)) {
            if (next.generation != command.generation) {
                engine.reset(next.seed);
                pending = null;
                last_completed_sample = 0;
                pass_start_us = idf.sys.esp_timer_get_time();
                paused_at_us = if (next.active) null else pass_start_us;
            } else if (command.active and !next.active) {
                paused_at_us = idf.sys.esp_timer_get_time();
            } else if (!command.active and next.active) {
                if (paused_at_us) |paused| pass_start_us += idf.sys.esp_timer_get_time() - paused;
                paused_at_us = null;
            }
            if (next.generation != command.generation or !command.active) {
                last_log = idf.sys.esp_timer_get_time();
                paths = 0;
                rays = 0;
                buckets = 0;
                compute_us = 0;
                peak_us = 0;
            }
            command = next;
        }
        if (!command.active) continue;
        if (pending == null) {
            const start_us = idf.sys.esp_timer_get_time();
            const bucket = engine.renderNext() orelse {
                idf.rtos.Task.delayMs(20);
                continue;
            };
            const duration = idf.sys.esp_timer_get_time() - start_us;
            pending = .{ .generation = command.generation, .bucket = bucket };
            compute_us += duration;
            peak_us = @max(peak_us, duration);
            buckets += 1;
            paths += bucket.counters.paths;
            rays += @as(u64, bucket.counters.rays) + bucket.counters.shadow_rays;
            if (engine.samples != last_completed_sample) {
                log.info("Cornell pass complete: spp={d}, active={d} ms", .{ engine.samples, @divTrunc(idf.sys.esp_timer_get_time() - pass_start_us, 1000) });
                pass_start_us = idf.sys.esp_timer_get_time();
                last_completed_sample = engine.samples;
            }
        }
        if (idf.rtos.Queue.send(result_queue, &pending.?, 0)) pending = null;
        // Every bucket/backpressure retry yields to IDLE0, preventing watchdog
        // starvation. The worker never takes LVGL's lock or writes its bitmap.
        idf.rtos.Task.delayMs(1);
        const now_us = idf.sys.esp_timer_get_time();
        if (now_us - last_log >= 2_000_000 and buckets > 0) {
            const elapsed: u64 = @intCast(now_us - last_log);
            log.info("Path tracer: spp={d}, bucket={d}/{d}, paths/s={d}, rays/s={d}, avg bucket={d} us, max bucket={d} us, stack={d}", .{ engine.samples, engine.cursor, engine.bucketCount(), paths * 1_000_000 / elapsed, rays * 1_000_000 / elapsed, @divTrunc(compute_us, buckets), peak_us, idf.rtos.Task.getStackHighWaterMark(null) });
            last_log = now_us;
            paths = 0;
            rays = 0;
            buckets = 0;
            compute_us = 0;
            peak_us = 0;
        }
    }
}
