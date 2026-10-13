const std = @import("std");
const idf = @import("esp_idf");
const ui = @import("../ui/fluid.zig");
const core = ui.core;
const pixel = @import("../ui/pixel_canvas.zig");
const pointer = @import("../ui/pointer.zig");
const log = std.log.scoped(idf.log.default_log_scope);
const Command = struct { active: bool, generation: u32, gravity: core.Vec, brushes: ui.Brushes, pause_ticket: u32 };
var pause: @import("../power/pause.zig").Latch = .{};
pub fn isPaused() bool {
    return pause.quiet();
}
var control_queue: idf.rtos.QueueHandle = null;
var snapshot_queue: idf.rtos.QueueHandle = null;
var initialized = false;
var active = false;
var failed = false;
var have_frame = false;
var control: ui.Controller = .{}; // This group is owned exclusively by LVGL.
var gravity: ui.Gravity = .{};
var previous: ui.Snapshot = .{};
var cache: ui.Snapshot = .{};
var incoming: ui.Snapshot = .{};
var particle_heap = idf.heap.HeapCapsAllocator.init(.{ .internal = true, .@"8bit" = true });
// Initialized before task creation, then owned exclusively by the worker.
var world: core.World = undefined;
var outgoing: ui.Snapshot = .{};
pub fn setActive(value: bool) !void {
    if (!initialized and !value) return;
    if (!initialized) start() catch |err| {
        failed = true;
        return err;
    };
    active = value;
    if (!value) pause.request();
    control.cancel();
    publish(0);
}
fn start() !void {
    world = try core.World.init(particle_heap.allocator());
    errdefer world.deinit();
    control_queue = try idf.rtos.Queue.create(1, @sizeOf(Command));
    errdefer idf.rtos.Queue.delete(control_queue);
    snapshot_queue = try idf.rtos.Queue.create(1, @sizeOf(ui.Snapshot));
    errdefer idf.rtos.Queue.delete(snapshot_queue);
    _ = try idf.rtos.Task.createPinnedToCore(worker, "rt_fluid", 8192, null, 2, 0);
    initialized = true;
    failed = false;
    log.info("RT ready: 32x32 mass distributions, total mass=512, points-only / 2x, target=120 steps/s, core=0; internal state={d}, snapshot={d} bytes, extra graphics PSRAM=0; tilt, multi-touch stir, RESET", .{ world.memoryBytes(), @sizeOf(ui.Snapshot) });
    log.info("RT heap: internal free={d}, largest={d} bytes", .{ particle_heap.freeSize(), particle_heap.largestFreeBlock() });
}
fn publish(now: u64) void {
    if (!initialized) return;
    const command: Command = .{ .active = active, .generation = control.generation, .gravity = gravity.vector, .brushes = control.brushes(now), .pause_ticket = pause.ticket };
    idf.rtos.Queue.overwrite(control_queue, &command);
}
pub fn input(kind: pointer.Event, id: u8, x: i32, y: i32, now: u64) void {
    if (!initialized) return;
    if (control.input(kind, id, x, y, now) == .reset) {
        have_frame = false;
        log.info("RT reset: generation={d}", .{control.generation});
    }
    publish(now);
}
pub fn cancel() void {
    if (!initialized) return;
    control.cancel();
    publish(0);
}
pub const Update = struct { region: ?pixel.Region = null, full: bool = false };
pub fn poll(now: u64, accel: ?[3]f32) Update {
    var update: Update = .{};
    if (!initialized) return update;
    gravity.update(accel);
    publish(now);
    if (idf.rtos.Queue.receive(snapshot_queue, &incoming, 0) and incoming.generation == control.generation) {
        update.full = !have_frame;
        previous = cache;
        cache = incoming;
        if (!update.full) update.region = ui.damage(&previous, &cache);
        have_frame = true;
    }
    return update;
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
    _ = idf.rtos.Queue.receive(control_queue, &command, idf.rtos.portMAX_DELAY);
    var clock: ui.Clock = .{};
    var last_render: u64 = 0;
    var window = nowUs();
    var steps: u32 = 0;
    var frames: u32 = 0;
    var wakes: u32 = 0;
    var sim_us: u64 = 0;
    var pack_us: u64 = 0;
    var max_step_us: u64 = 0;
    var pairs: u64 = 0;
    var candidates: u64 = 0;
    var clamps: u32 = 0;
    var stirred: u64 = 0;
    while (true) {
        if (!command.active) pause.ack(command.pause_ticket);
        var next: Command = undefined;
        const wait = if (command.active) idf.rtos.msToTicks(clock.waitMs(nowUs(), last_render + 33_333)) else idf.rtos.portMAX_DELAY;
        const received = idf.rtos.Queue.receive(control_queue, &next, wait);
        if (received) {
            if (next.generation != command.generation) {
                world.reset();
                clock.clear();
                last_render = 0;
            }
            if (!command.active or !next.active) {
                clock.clear();
                window = nowUs();
                steps = 0;
                frames = 0;
                wakes = 0;
                sim_us = 0;
                pack_us = 0;
                max_step_us = 0;
                pairs = 0;
                candidates = 0;
                clamps = 0;
                stirred = 0;
                last_render = 0;
            }
            command = next;
        }
        if (!command.active) continue;
        // An already queued command does not block. Preserve an IDLE slot if
        // input keeps arriving while simulation is due/overloaded.
        if (received and clock.waitMs(nowUs(), null) == 1) idf.rtos.Task.delayMs(1);
        wakes += 1;
        const tick = nowUs();
        const count = clock.advance(tick);
        for (0..count) |_| {
            const start_us = nowUs();
            const stats = world.step(command.gravity, command.brushes.items[0..command.brushes.count]);
            const duration = nowUs() - start_us;
            steps += 1;
            sim_us += duration;
            max_step_us = @max(max_step_us, duration);
            pairs += stats.pairs;
            candidates += stats.candidates;
            clamps += stats.speed_clamps;
            stirred += stats.stirred;
        }
        if (tick -| last_render >= 33_333) {
            const start_us = nowUs();
            ui.Snapshot.capture(&world, command.generation, &outgoing);
            idf.rtos.Queue.overwrite(snapshot_queue, &outgoing);
            pack_us += nowUs() - start_us;
            frames += 1;
            last_render = tick;
        }
        const now = nowUs();
        if (now - window >= 2_000_000 and steps > 0) {
            var max_density: f32 = 0;
            for (world.particles[0..world.count]) |p| max_density = @max(max_density, p.density);
            log.info("RT: steps/s={d}, frames/s={d}, wakes/s={d}, avg/max step={d}/{d} us, pack={d} us, pairs/candidates={d}/{d}, stirred={d}, clamps={d}, max density={d} permille, mass={d} milli, dots={d}, dropped={d} ms, stack={d}", .{ @as(u64, steps) * 1_000_000 / (now - window), @as(u64, frames) * 1_000_000 / (now - window), @as(u64, wakes) * 1_000_000 / (now - window), sim_us / steps, max_step_us, pack_us / @max(1, frames), pairs / steps, candidates / steps, stirred / @max(1, steps), clamps, @as(u32, @intFromFloat(max_density * 1000 / world.reference_mass)), @as(u32, @intFromFloat(world.totalMass() * 1000)), outgoing.count, clock.dropped_us / 1000, idf.rtos.Task.getStackHighWaterMark(null) });
            window = now;
            steps = 0;
            frames = 0;
            wakes = 0;
            sim_us = 0;
            pack_us = 0;
            max_step_us = 0;
            pairs = 0;
            candidates = 0;
            clamps = 0;
            stirred = 0;
            clock.dropped_us = 0;
        }
    }
}
