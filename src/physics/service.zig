//! Core 0 owns simulation; LVGL owns input and copies the latest pose snapshot.
const std = @import("std");
const idf = @import("esp_idf");
const ui = @import("../ui/physics.zig");
const core = ui.core;
const pixel = @import("../ui/pixel_canvas.zig");
const pointer = @import("../ui/pointer.zig");
const log = std.log.scoped(idf.log.default_log_scope);
const Command = struct { active: bool, generation: u32, gravity: core.Vec, grabs: core.Grabs, pause_ticket: u32 };
var pause: @import("../power/pause.zig").Latch = .{};
pub fn isPaused() bool {
    return pause.quiet();
}
var command_queue: idf.rtos.QueueHandle = null;
var snapshot_queue: idf.rtos.QueueHandle = null;
var initialized = false;
var active = false;
var failed = false;
var have_frame = false;
var controller: ui.Controller = .{};
var gravity: ui.Gravity = .{};
var cache: ui.Snapshot = .{};
var previous: ui.Snapshot = .{};
var incoming: ui.Snapshot = .{};
var heap = idf.heap.HeapCapsAllocator.init(.{ .spiram = true, .@"8bit" = true });
var world: *core.World = undefined;
var outgoing: ui.Snapshot = .{};
fn start() !void {
    world = try core.World.create(heap.allocator());
    errdefer heap.allocator().destroy(world);
    command_queue = try idf.rtos.Queue.create(1, @sizeOf(Command));
    errdefer idf.rtos.Queue.delete(command_queue);
    snapshot_queue = try idf.rtos.Queue.create(1, @sizeOf(ui.Snapshot));
    errdefer idf.rtos.Queue.delete(snapshot_queue);
    _ = try idf.rtos.Task.createPinnedToCore(worker, "rigid_2d", 8192, null, 2, 0);
    initialized = true;
    failed = false;
    log.info("Rigid ready: {d} bodies, balls + rotating boxes, target={d} steps/s, core=0, world PSRAM={d}, snapshot={d} bytes, extra graphics PSRAM=0; proportional tilt / flat zero, multi-finger drag and throw, RESET", .{ core.max_bodies, core.hz, @sizeOf(core.World), @sizeOf(ui.Snapshot) });
}
pub fn setActive(value: bool) !void {
    if (!initialized and !value) return;
    if (!initialized) start() catch |err| {
        failed = true;
        return err;
    };
    active = value;
    if (!value) pause.request();
    controller.cancel();
    publish(0);
}
fn publish(now: u64) void {
    if (!initialized) return;
    const command: Command = .{ .active = active, .generation = controller.generation, .gravity = gravity.vector.scale(2.5), .grabs = controller.grabs(now), .pause_ticket = pause.ticket };
    idf.rtos.Queue.overwrite(command_queue, &command);
}
pub fn input(kind: pointer.Event, id: u8, x: i32, y: i32, now: u64) void {
    if (!initialized) return;
    if (controller.input(kind, id, x, y, now, if (have_frame) &cache else null)) {
        have_frame = false;
        log.info("Rigid reset: generation={d}", .{controller.generation});
    }
    publish(now);
}
pub fn cancel() void {
    if (!initialized) return;
    controller.cancel();
    publish(0);
}
pub const Update = struct { region: ?pixel.Region = null, full: bool = false };
pub fn poll(now: u64, accel: ?[3]f32) Update {
    var result: Update = .{};
    if (!initialized) return result;
    gravity.update(accel);
    publish(now);
    if (idf.rtos.Queue.receive(snapshot_queue, &incoming, 0) and incoming.generation == controller.generation) {
        result.full = !have_frame;
        previous = cache;
        cache = incoming;
        if (!result.full) result.region = ui.damage(&previous, &cache);
        have_frame = true;
    }
    return result;
}
pub fn paintFull(canvas: pixel.Canvas) void {
    ui.paintFull(canvas, if (have_frame) &cache else null, failed);
}
pub fn paint(canvas: pixel.Canvas, update: Update) void {
    if (update.region != null) ui.paintChanges(canvas, &previous, &cache);
}
fn nowUs() u64 {
    return @intCast(idf.sys.esp_timer_get_time());
}
fn worker(_: ?*anyopaque) callconv(.c) void {
    var command: Command = undefined;
    _ = idf.rtos.Queue.receive(command_queue, &command, idf.rtos.portMAX_DELAY);
    var clock: ui.Clock = .{};
    var last_frame: u64 = 0;
    var window = nowUs();
    var steps: u32 = 0;
    var frames: u32 = 0;
    var wakes: u32 = 0;
    var sim_us: u64 = 0;
    var max_us: u64 = 0;
    var candidates: u64 = 0;
    var contacts: u64 = 0;
    var grabbed: u64 = 0;
    while (true) {
        if (!command.active) pause.ack(command.pause_ticket);
        var next: Command = undefined;
        const wait = if (command.active) idf.rtos.msToTicks(clock.waitMs(nowUs(), last_frame + 33_333)) else idf.rtos.portMAX_DELAY;
        const received = idf.rtos.Queue.receive(command_queue, &next, wait);
        if (received) {
            if (next.generation != command.generation) {
                world.reset();
                clock.clear();
                last_frame = 0;
            }
            if (!next.active or !command.active) {
                clock.clear();
                clock.dropped_us = 0;
                window = nowUs();
                last_frame = 0;
                steps = 0;
                frames = 0;
                wakes = 0;
                sim_us = 0;
                max_us = 0;
                candidates = 0;
                contacts = 0;
                grabbed = 0;
            }
            command = next;
        }
        if (!command.active) continue;
        // Do not starve IDLE when a full command queue bypasses the wait.
        if (received and clock.waitMs(nowUs(), null) == 1) idf.rtos.Task.delayMs(1);
        wakes += 1;
        const tick = nowUs();
        const count = clock.advance(tick);
        for (0..count) |_| {
            const start_us = nowUs();
            const stats = world.step(command.gravity, command.grabs.items[0..command.grabs.count]);
            const duration = nowUs() - start_us;
            steps += 1;
            sim_us += duration;
            max_us = @max(max_us, duration);
            candidates += stats.candidates;
            contacts += stats.contacts;
            grabbed += stats.grabbed;
        }
        if (tick -| last_frame >= 33_333) {
            ui.Snapshot.capture(world, command.generation, &outgoing);
            idf.rtos.Queue.overwrite(snapshot_queue, &outgoing);
            frames += 1;
            last_frame = tick;
        }
        const now = nowUs();
        if (now - window >= 2_000_000 and steps > 0) {
            log.info("Rigid: steps/s={d}, frames/s={d}, wakes/s={d}, avg/max step={d}/{d} us, candidates/contacts={d}/{d}, grabbed={d}, dropped={d} ms, stack={d}", .{ @as(u64, steps) * 1_000_000 / (now - window), @as(u64, frames) * 1_000_000 / (now - window), @as(u64, wakes) * 1_000_000 / (now - window), sim_us / steps, max_us, candidates / steps, contacts / steps, grabbed / steps, clock.dropped_us / 1000, idf.rtos.Task.getStackHighWaterMark(null) });
            window = now;
            steps = 0;
            frames = 0;
            wakes = 0;
            sim_us = 0;
            max_us = 0;
            candidates = 0;
            contacts = 0;
            grabbed = 0;
            clock.dropped_us = 0;
        }
    }
}
