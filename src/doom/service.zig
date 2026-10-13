const std = @import("std");
const idf = @import("esp_idf");
const ui = @import("../ui/doom.zig");
const pixel = @import("../ui/pixel_canvas.zig");
const pointer = @import("../ui/pointer.zig");
const log = std.log.scoped(idf.log.default_log_scope);
extern fn badge_doom_start() c_int;
extern fn badge_doom_tick() c_int;
extern fn badge_doom_error() [*:0]const u8;
extern fn badge_doom_tic() c_int;
extern var DG_ScreenBuffer: [*]u16;
const Command = struct { active: bool, keys: u16, pause_ticket: u32 = 0 };
var pause: @import("../power/pause.zig").Latch = .{};
pub fn isPaused() bool {
    return pause.quiet();
}
const Packet = struct { index: u8 = 0, failed: bool = false };
var control_queue: idf.rtos.QueueHandle = null;
var free_queue: idf.rtos.QueueHandle = null;
var ready_queue: idf.rtos.QueueHandle = null;
var initialized = false;
var active = false; // LVGL-owned.
var failed = false;
var have_frame = false;
var control: ui.Controller = .{};
var controls_dirty = false;
var storage: []align(16) u16 = undefined;
var cache: []align(16) u16 = undefined;
var heap = idf.heap.HeapCapsAllocator.init(.{ .spiram = true, .@"8bit" = true });
// Everything below belongs exclusively to the engine task.
var command: Command = undefined;
var clock: ui.Clock = undefined;
var emitted: ui.Keys = .{};
var window_start_us: i64 = 0;
var drawn: u32 = 0;
var dropped: u32 = 0;

pub fn setActive(value: bool) !void {
    if (!initialized and !value) return;
    if (!initialized) try start();
    active = value;
    if (!value) pause.request();
    _ = control.input(.cancel, 0, 0);
    controls_dirty = true;
    const next: Command = .{ .active = value, .keys = 0, .pause_ticket = pause.ticket };
    idf.rtos.Queue.overwrite(control_queue, &next);
}
fn start() !void {
    storage = try heap.allocator().alignedAlloc(u16, .@"16", ui.pixel_count * 2);
    errdefer heap.allocator().free(storage);
    cache = try heap.allocator().alignedAlloc(u16, .@"16", ui.pixel_count);
    errdefer heap.allocator().free(cache);
    @memset(cache, 0);
    control_queue = try idf.rtos.Queue.create(1, @sizeOf(Command));
    errdefer idf.rtos.Queue.delete(control_queue);
    free_queue = try idf.rtos.Queue.create(2, @sizeOf(u8));
    errdefer idf.rtos.Queue.delete(free_queue);
    ready_queue = try idf.rtos.Queue.create(2, @sizeOf(Packet));
    errdefer idf.rtos.Queue.delete(ready_queue);
    for (0..2) |i| {
        const index: u8 = @intCast(i);
        _ = idf.rtos.Queue.send(free_queue, &index, 0);
    }
    _ = try idf.rtos.Task.createPinnedToCore(worker, "doom_engine", 16384, null, 2, 0);
    initialized = true;
}
pub fn input(event: pointer.Event, x: i32, y: i32) void {
    if (!initialized or failed) return;
    if (control.input(event, x, y)) {
        const next: Command = .{ .active = active, .keys = control.keys, .pause_ticket = pause.ticket };
        idf.rtos.Queue.overwrite(control_queue, &next);
        controls_dirty = true;
    }
}
pub const Update = struct { frame: bool = false, controls: bool = false, full: bool = false };
pub fn poll() Update {
    var result: Update = .{};
    if (!initialized) return result;
    for (0..2) |_| {
        var packet: Packet = undefined;
        if (!idf.rtos.Queue.receive(ready_queue, &packet, 0)) break;
        if (packet.failed) {
            failed = true;
            result.full = true;
        } else {
            const start_index = @as(usize, packet.index) * ui.pixel_count;
            @memcpy(cache, storage[start_index..][0..ui.pixel_count]);
            _ = idf.rtos.Queue.send(free_queue, &packet.index, 0);
            have_frame = true;
            result.frame = true;
        }
    }
    result.controls = controls_dirty;
    controls_dirty = false;
    return result;
}
pub fn paintFull(canvas: pixel.Canvas) void {
    ui.paintFull(canvas, if (have_frame) cache else null, control.keys, failed);
}
pub fn paint(canvas: pixel.Canvas, update: Update) void {
    if (update.frame) ui.paintGame(canvas, cache);
    if (update.controls) ui.controls(canvas, control.keys);
}
fn nowMs() u64 {
    return @intCast(@divTrunc(idf.sys.esp_timer_get_time(), 1000));
}
fn worker(_: ?*anyopaque) callconv(.c) void {
    _ = idf.rtos.Queue.receive(control_queue, &command, idf.rtos.portMAX_DELAY);
    clock = .{ .epoch_ms = nowMs() };
    clock.setActive(command.active, nowMs());
    var started = false;
    while (true) {
        if (!command.active) pause.ack(command.pause_ticket);
        var next: Command = undefined;
        if (idf.rtos.Queue.receive(control_queue, &next, if (command.active) 0 else idf.rtos.portMAX_DELAY)) {
            if (!command.active and next.active) {
                window_start_us = idf.sys.esp_timer_get_time();
                drawn = 0;
                dropped = 0;
            }
            clock.setActive(next.active, nowMs());
            command = next;
        }
        if (!command.active) continue;
        const start_us = idf.sys.esp_timer_get_time();
        const status = if (started) badge_doom_tick() else badge_doom_start();
        if (status != 0) {
            log.err("Doom stopped: {s}; page navigation remains available", .{std.mem.span(badge_doom_error())});
            const packet: Packet = .{ .failed = true };
            _ = idf.rtos.Queue.send(ready_queue, &packet, idf.rtos.portMAX_DELAY);
            pause.stop();
            idf.rtos.Task.delete(null);
            return;
        }
        if (!started) {
            log.info("Doom ready: 320x200 RGB565, 320x240 aspect correction, zone=4 MiB, core=0; touch pad/FIRE/USE/OK/MENU", .{});
            started = true;
        }
        const elapsed_ms: u32 = @intCast(@divTrunc(idf.sys.esp_timer_get_time() - start_us, 1000));
        idf.rtos.Task.delayMs(if (elapsed_ms < 50) 50 - elapsed_ms else 1);
    }
}
export fn DG_Init() callconv(.c) void {}
export fn DG_GetTicksMs() callconv(.c) u32 {
    return clock.ticks(nowMs());
}
export fn DG_SleepMs(ms: u32) callconv(.c) void {
    idf.rtos.Task.delayMs(@max(1, ms));
}
export fn DG_GetKey(pressed: *c_int, key: *u8) callconv(.c) c_int {
    const event = emitted.next(command.keys) orelse return 0;
    pressed.* = if (event.pressed) 1 else 0;
    key.* = event.code;
    return 1;
}
export fn DG_SetWindowTitle(_: [*:0]const u8) callconv(.c) void {}
export fn DG_DrawFrame() callconv(.c) void {
    var index: u8 = undefined;
    if (idf.rtos.Queue.receive(free_queue, &index, 0)) {
        const offset = @as(usize, index) * ui.pixel_count;
        @memcpy(storage[offset..][0..ui.pixel_count], DG_ScreenBuffer[0..ui.pixel_count]);
        const packet: Packet = .{ .index = index };
        if (!idf.rtos.Queue.send(ready_queue, &packet, 0)) _ = idf.rtos.Queue.send(free_queue, &index, 0);
        drawn += 1;
    } else dropped += 1;
    const now_us = idf.sys.esp_timer_get_time();
    if (window_start_us == 0) window_start_us = now_us;
    if (now_us - window_start_us >= 2_000_000) {
        var hash: u32 = 2166136261;
        var ink: u32 = 0;
        var i: usize = 0;
        while (i < ui.pixel_count) : (i += 113) {
            const value = DG_ScreenBuffer[i];
            hash = (hash ^ value) *% 16777619;
            if (value != 0) ink += 1;
        }
        const fps10 = @as(u64, drawn) * 10_000_000 / @as(u64, @intCast(now_us - window_start_us));
        log.info("Doom frames: {d}.{d}/s, delivered={d}, dropped={d}, tic={d}, hash={x}, ink={d}/567, stack={d}", .{ fps10 / 10, fps10 % 10, drawn, dropped, badge_doom_tic(), hash, ink, idf.rtos.Task.getStackHighWaterMark(null) });
        window_start_us = now_us;
        drawn = 0;
        dropped = 0;
    }
}
