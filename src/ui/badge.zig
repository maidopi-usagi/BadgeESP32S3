const std = @import("std");
const idf = @import("esp_idf");
const display = @import("board").Display;
const model = @import("fumo.zig");
const interaction = model.interaction;
const navigation = @import("navigation.zig");
const pointer = @import("pointer.zig");
const dice = @import("dice.zig");
const jirai = @import("jirai.zig");
const colors = @import("theme.zig").colors;
const pixel = @import("pixel_canvas.zig");
const viewport = pixel.Viewport.init(@import("render_options").pixel_scale);
const log = std.log.scoped(idf.log.default_log_scope);
const motion = @import("../motion/service.zig");
const parallax = @import("../motion/parallax.zig");
const cornell = @import("cornell.zig");
const trace_service = @import("../render/service.zig");
const doom = @import("doom.zig");
const doom_service = @import("../doom/service.zig");
const sandbox = @import("sandbox.zig");
const rhythm = @import("rhythm.zig");
const rhythm_audio = @import("../rhythm/service.zig");
const touches = @import("../input/multitouch.zig");
const fluid = @import("fluid.zig");
const fluid_service = @import("../fluid/service.zig");
const physics_service = @import("../physics/service.zig");
comptime {
    if (interaction.parallax_angle_limit != parallax.max_angle) @compileError("Sensor and renderer parallax limits must match");
}

const frame_period_ms = 33;
var animation: interaction.State = .{};
var router: navigation.Router = .{ .active = @field(navigation.Demo, @import("render_options").start_demo) };
var dice_state: dice.State = .{};
var dice_tap: pointer.Tap = .{};
var dice_perf: CallbackPerf = .{};
var dice_report_ms: u64 = 0;
var dice_report_steps: u64 = 0;
var dice_report_substeps: u64 = 0;
var trace_tap: pointer.Tap = .{};
var sandbox_state: ?sandbox.State = null;
var rhythm_state: rhythm.game.State = .{};
var rhythm_pixels: ?[]u16 = null;
var rhythm_center: pointer.Tap = .{};
var rhythm_center_id: ?u8 = null;
var rhythm_center_y: i32 = 0;
var rhythm_return_playing = false;
var rhythm_dirty = true;
var touch_tracker: touches.Tracker = .{};
var legacy_primary: ?u8 = null;
var multi_edge_id: ?u8 = null;
var touch_blocked = false;
var full_refresh = false;
var fluid_perf: CallbackPerf = .{};
var physics_perf: CallbackPerf = .{};
var last_dice_frame_ms: ?u64 = null;
var paint_ms: u64 = 0;
var view: parallax.View = .{};
var render_pose: model.Pose = .{};
var renderer: model.Renderer = undefined;
var canvas: pixel.Canvas = undefined;
var frame: []u16 = undefined;
var image: display.Object = undefined;
var ready = false;
var scene_start_ms: u64 = 0;
var scene_ms: u64 = 0;
var heap = idf.heap.HeapCapsAllocator.init(.{ .spiram = true, .@"8bit" = true });
var sleep_started_ms: u64 = 0;

/// The power task calls these with the LVGL worker paused and display locked.
pub fn pauseForSleep(now: u64) void {
    sleep_started_ms = now;
    if (router.active == .rhythm) {
        advanceRhythm(now);
        rhythm_return_playing = rhythm_state.phase == .playing or rhythm_state.phase == .waiting;
        if (rhythm_return_playing) rhythm_state.phase = .paused;
    }
    cancelContent(now);
    _ = router.route(.cancel, 0, 0, now);
    touch_tracker = .{};
    legacy_primary = null;
    multi_edge_id = null;
    touch_blocked = true;
    rhythm_state.current_touches = 0;
    trace_service.setActive(false) catch {};
    doom_service.setActive(false) catch {};
    fluid_service.setActive(false) catch {};
    physics_service.setActive(false) catch {};
    rhythm_audio.request(false, rhythm_state.song_ms) catch {};
    motion.pauseForSleep();
    log.info("Power: pausing page={s}", .{@tagName(router.active)});
}

pub fn busyWorkers() u8 {
    var mask: u8 = 0;
    if (!trace_service.isPaused()) mask |= 1;
    if (!doom_service.isPaused()) mask |= 2;
    if (!fluid_service.isPaused()) mask |= 4;
    if (!physics_service.isPaused()) mask |= 8;
    if (!rhythm_audio.isPaused()) mask |= 16;
    if (!motion.isPaused()) mask |= 32;
    return mask;
}

pub fn resumeAfterSleep(now: u64) void {
    const elapsed = now -| sleep_started_ms;
    animation.last_ms = now;
    if (animation.last_touch_ms) |*last| last.* +|= elapsed;
    scene_start_ms +|= elapsed;
    dice_state.reenter(now);
    dice_report_ms = now;
    dice_report_steps = dice_state.world.steps;
    dice_report_substeps = dice_state.world.substeps;
    last_dice_frame_ms = null;
    if (sandbox_state) |*state| state.reenter(now);
    motion.setPage(router.active);
    trace_service.setActive(router.active == .cornell) catch |err| log.err("Cornell resume: {s}", .{@errorName(err)});
    doom_service.setActive(router.active == .doom) catch |err| log.err("Doom resume: {s}", .{@errorName(err)});
    fluid_service.setActive(router.active == .fluid) catch |err| log.err("Fluid resume: {s}", .{@errorName(err)});
    physics_service.setActive(router.active == .physics) catch |err| log.err("Rigid resume: {s}", .{@errorName(err)});
    if (router.active == .rhythm) startRhythm() catch |err| log.err("Orbit resume: {s}", .{@errorName(err)});
    rhythm_dirty = true;
    full_refresh = true;
    display.badge_touch_resync();
    log.info("Power: resumed page={s}, paused={d} ms", .{ @tagName(router.active), elapsed });
}

pub fn init() !void {
    const pixels = try heap.allocator().alignedAlloc(u16, .@"4", @as(usize, viewport.logical_size) * viewport.logical_size);
    errdefer heap.allocator().free(pixels);
    frame = try heap.allocator().alignedAlloc(u16, .@"4", pixel.Viewport.panel_size * pixel.Viewport.panel_size);
    errdefer heap.allocator().free(frame);
    canvas = pixel.Canvas.init(pixels, viewport.logical_size, viewport.logical_size);
    renderer = try model.Renderer.init(heap.allocator(), viewport.logical_size, viewport.logical_size);
    errdefer renderer.deinit();
    if (router.active == .cornell) trace_service.setActive(true) catch |err| log.err("Cornell startup failed: {s}", .{@errorName(err)});
    if (router.active == .doom) doom_service.setActive(true) catch |err| log.err("Doom startup failed: {s}", .{@errorName(err)});
    if (router.active == .sandbox) startSandbox(0) catch |err| log.err("Sandbox startup failed: {s}", .{@errorName(err)});
    if (router.active == .rhythm) try startRhythm();
    if (router.active == .fluid) try fluid_service.setActive(true);
    if (router.active == .physics) try physics_service.setActive(true);
    draw(true, true);
    try display.start();
    try display.lock();
    defer display.unlock();
    image = display.badge_ui_pixels(frame.ptr, pixel.Viewport.panel_size, 1, 0) orelse return error.ImageCreateFailed;
    scene_start_ms = @intCast(@divTrunc(idf.sys.esp_timer_get_time(), 1000));
    _ = animation.advance(scene_start_ms);
    dice_state.reenter(scene_start_ms);
    if (sandbox_state) |*state| state.reenter(scene_start_ms);
    // Timer and touch callbacks both execute inside LVGL's display mutex.
    display.animate(frame_period_ms) catch |err| {
        log.err("Animation startup failed: {s}", .{@errorName(err)});
    };
    ready = true;
    motion.start(router.active) catch |err| log.err("Motion startup failed: {s}", .{@errorName(err)});
    log.info("Fumo ready: {d}x{d} RGB565, {d}x row expansion, border={d}px, source={d} bytes, staging={d} bytes, timer={d} ms; drag orbits, tap bounces, synthwave grid", .{
        viewport.logical_size, viewport.logical_size, viewport.scale, viewport.offset, pixels.len * 2, frame.len * 2, frame_period_ms,
    });
    log.info("Fumo mesh: {d} vertices, {d} triangles, texture={d}x{d} RGB565 ({d} bytes), renderer RAM={d} bytes", .{ model.vertex_count, model.triangle_count, model.texture_size, model.texture_size, renderer.texture.len * 2, renderer.memoryBytes() });
    log.info("Touch idle resume={d} ms; gyro parallax={d} deg", .{ interaction.idle_resume_ms, parallax.max_degrees });
    log.info("Dice: physical 3D cube, {d} Hz; continuous six-axis forces, contact/friction/bounce; tap adds impulse, result measured after sleep", .{dice.core.hz});
    log.info("Demos ready: 1=Fumo, 2=DICE, 3=Cornell, 4=Doom, 5=Sandbox, 6=Orbit Beat, 7=RT Fluid, 8=Rigid Toys; start={s}; rim={d}px, inward swipe={d}px; center interacts", .{ @tagName(router.active), navigation.edge_width, navigation.swipe_distance });
    if (router.active == .rhythm and @import("render_options").rhythm_autoplay) {
        rhythm_state.start();
        try rhythm_audio.request(true, 0);
        log.info("Orbit automatic playback measurement started", .{});
    }
}

fn startRhythm() !void {
    if (rhythm_pixels == null) {
        rhythm_pixels = try heap.allocator().alloc(u16, 233 * 233 * 2);
        rhythm.backdrop(pixel.Canvas.init(rhythm_pixels.?[233 * 233 ..], 233, 233));
        log.info("Orbit ready: 233x233 / 2x, 8 lanes, 120 BPM; Tap/Hold/Slide, 2-/5-note chords, up to 5 contacts; cached graphics RAM=217156 bytes", .{});
    }
    if (rhythm_return_playing) {
        rhythm_state.resumeSong();
        try rhythm_audio.request(true, rhythm_state.song_ms);
        rhythm_return_playing = false;
    }
}
fn drawRhythm(full: bool) void {
    const pixels = rhythm_pixels orelse return;
    const work = pixels[0 .. 233 * 233];
    @memcpy(work, pixels[233 * 233 ..]);
    const source = pixel.Canvas.init(work, 233, 233);
    rhythm.foreground(source, &rhythm_state);
    if (full) {
        pixel.expandNearest(source, frame, rhythm.viewport);
        if (ready) display.badge_ui_pixels_changed(image);
    } else {
        const damage = pixel.Damage.between(source, frame, rhythm.viewport);
        for (damage.regions[0..damage.len]) |region| {
            pixel.expandNearestRegion(source, frame, rhythm.viewport, region);
            display.badge_ui_pixels_changed_area(image, region.x * 2, region.y * 2, region.width * 2, region.height * 2);
        }
    }
}
fn advanceRhythm(now: u64) void {
    if (rhythm_state.phase == .waiting or rhythm_state.phase == .playing) {
        if (rhythm_audio.poll(now)) |snapshot| switch (snapshot.status) {
            .playing, .done => {
                rhythm_state.phase = .playing;
                rhythm_state.advance(snapshot.position_ms);
                if (snapshot.status == .done) rhythm_state.advance(rhythm.game.duration_ms);
            },
            .failed => rhythm_state.phase = .failed,
        };
    }
}
fn rhythmFrame(now: u64) void {
    const start = idf.sys.esp_timer_get_time();
    const before = rhythm_state.phase;
    advanceRhythm(now);
    if (full_refresh or rhythm_dirty or before != rhythm_state.phase or rhythm_state.phase == .playing) drawRhythm(full_refresh);
    rhythm_dirty = false;
    full_refresh = false;
    const end = idf.sys.esp_timer_get_time();
    if (rhythm_perf_start == 0) rhythm_perf_start = start;
    rhythm_perf_frames += 1;
    rhythm_perf_us += end - start;
    rhythm_perf_max = @max(rhythm_perf_max, end - start);
    if (end - rhythm_perf_start >= 2_000_000) {
        log.info("Orbit UI: phase={s}, song={d} ms, avg/max callback={d}/{d} us, score={d}, contacts={d}/{d}", .{ @tagName(rhythm_state.phase), rhythm_state.song_ms, @divTrunc(rhythm_perf_us, rhythm_perf_frames), rhythm_perf_max, rhythm_state.score, rhythm_state.current_touches, rhythm_state.max_touches });
        rhythm_perf_start = end;
        rhythm_perf_frames = 0;
        rhythm_perf_us = 0;
        rhythm_perf_max = 0;
    }
}
var rhythm_perf_start: i64 = 0;
var rhythm_perf_frames: u32 = 0;
var rhythm_perf_us: i64 = 0;
var rhythm_perf_max: i64 = 0;
fn rhythmInput(kind: pointer.Event, p: touches.Point, now: u64) void {
    rhythm_dirty = true;
    rhythm_state.touch(kind, p.id, p.x, p.y);
    const dx = @as(i32, p.x) - 233;
    const dy = @as(i32, p.y) - 233;
    if (kind == .down and dx * dx + dy * dy < 80 * 80 and rhythm_center_id == null) {
        rhythm_center_id = p.id;
        rhythm_center_y = p.y;
    }
    if (rhythm_center_id != p.id) return;
    const tapped = rhythm_center.pointer(kind, p.x, p.y, now);
    if (kind == .up or kind == .cancel) rhythm_center_id = null;
    if (!tapped) return;
    switch (rhythm_state.phase) {
        .ready => {
            if (rhythm_center_y >= 244) {
                _ = rhythm_state.cycleChart();
            } else {
                rhythm_state.start();
                rhythm_audio.request(true, 0) catch {
                    rhythm_state.phase = .failed;
                };
            }
        },
        .results, .failed => {
            if (rhythm_state.phase == .results and rhythm_center_y >= 274) {
                _ = rhythm_state.cycleChart();
            } else {
                rhythm_state.start();
                rhythm_audio.request(true, 0) catch {
                    rhythm_state.phase = .failed;
                };
            }
        },
        .paused => {
            rhythm_state.resumeSong();
            rhythm_audio.request(true, rhythm_state.song_ms) catch {
                rhythm_state.phase = .failed;
            };
        },
        .playing, .waiting => {
            rhythm_state.phase = .paused;
            rhythm_state.cancel();
            rhythm_audio.request(false, rhythm_state.song_ms) catch {};
        },
    }
    log.info("Orbit control: {s}, song={d} ms, score={d}, peak contacts={d}, level={s}", .{ @tagName(rhythm_state.phase), rhythm_state.song_ms, rhythm_state.score, rhythm_state.max_touches, @tagName(rhythm_state.difficulty) });
}
export fn badge_decode_touch(data: [*]const u8, length: u32, points: [*]touches.Point, orientation: u8) callconv(.c) c_int {
    const decoded = touches.decodeScreen(data[0..length], @bitCast(orientation)) catch return -1;
    @memcpy(points[0..decoded.count], decoded.points[0..decoded.count]);
    return decoded.count;
}
export fn badge_on_touches(points: [*]const touches.Point, count: u8, now: u64) callconv(.c) void {
    if (!ready or (count > touches.max_points and count != 255)) return;
    const valid = count != 255;
    const n: u8 = if (valid) count else 0;
    var touch_frame: touches.Frame = .{ .count = n };
    @memcpy(touch_frame.points[0..n], points[0..n]);
    const old_count = touch_tracker.count;
    var events = touch_tracker.update(touch_frame);
    if (events.count != 0 or rhythm_state.current_touches != n) rhythm_dirty = true;
    if (!valid) for (events.items[0..events.count]) |*event| {
        event.kind = .cancel;
    };
    rhythm_state.current_touches = n;
    if (n > rhythm_state.max_touches) {
        rhythm_state.max_touches = n;
        log.info("CST9217 measured simultaneous contacts: {d}", .{n});
    }
    if (touch_blocked) {
        if (valid and n == 0) touch_blocked = false;
        return;
    }
    if (router.active == .rhythm or router.active == .fluid or router.active == .physics) {
        if (router.active == .rhythm) advanceRhythm(now);
        if (multi_edge_id != null and n > 1) {
            _ = router.route(.cancel, 0, 0, now);
            multi_edge_id = null;
        }
        for (events.items[0..events.count]) |event| {
            const p = event.point;
            if (event.kind == .down and old_count == 0 and n == 1 and event.owner == .edge) multi_edge_id = p.id;
            if (multi_edge_id == p.id) {
                const before = router.active;
                badge_on_pointer(@backingInt(event.kind), p.x, p.y, now);
                if (event.kind == .up or event.kind == .cancel) multi_edge_id = null;
                if (before != router.active) {
                    touch_blocked = n != 0;
                    break;
                }
            } else if (event.owner == .content) {
                if (router.active == .rhythm) rhythmInput(event.kind, p, now) else if (router.active == .fluid) fluid_service.input(event.kind, p.id, p.x, p.y, now) else physics_service.input(event.kind, p.id, p.x, p.y, now);
            }
        }
    } else {
        if (old_count == 0 and n > 0) legacy_primary = points[0].id;
        for (events.items[0..events.count]) |event| if (legacy_primary == event.point.id) {
            const before = router.active;
            badge_on_pointer(@backingInt(event.kind), event.point.x, event.point.y, now);
            if (event.kind == .up or event.kind == .cancel) legacy_primary = null;
            if (before != router.active) {
                touch_blocked = n != 0;
                legacy_primary = null;
                break;
            }
        };
        if (n == 0) legacy_primary = null;
    }
}

var sandbox_perf_start: i64 = 0;
var sandbox_perf_frames: u32 = 0;
var sandbox_sim_us: i64 = 0;
var sandbox_paint_us: i64 = 0;
var sandbox_max_us: i64 = 0;
var sandbox_last_steps: u64 = 0;
var sandbox_last_moves: u64 = 0;
fn startSandbox(now_ms: u64) !void {
    if (sandbox_state == null) {
        sandbox_state = try sandbox.State.init(heap.allocator());
        log.info("Sandbox ready: 160x160 cells, 2x display, RAM={d} bytes; drag/hold draws, tap changes tool, CLEAR resets; absolute IMU gravity", .{sandbox.core.cell_count});
    }
    const state = &sandbox_state.?;
    state.reenter(now_ms);
    sandbox_perf_start = idf.sys.esp_timer_get_time();
    sandbox_perf_frames = 0;
    sandbox_sim_us = 0;
    sandbox_paint_us = 0;
    sandbox_max_us = 0;
    sandbox_last_steps = state.world.steps;
    sandbox_last_moves = state.world.moves;
}
fn sandboxFrame(now_ms: u64) void {
    const native = pixel.Canvas.init(frame, 466, 466);
    if (sandbox_state) |*state| {
        const start_us = idf.sys.esp_timer_get_time();
        state.advance(now_ms, motion.acceleration(now_ms));
        const simulated_us = idf.sys.esp_timer_get_time();
        const region = state.world.takeDamage();
        if (full_refresh) {
            sandbox.paintFull(native, state);
            display.badge_ui_pixels_changed(image);
        } else {
            if (region) |r| {
                sandbox.paintRegion(native, state.world, r);
                const physical = sandbox.physicalRegion(r);
                display.badge_ui_pixels_changed_area(image, physical.x, physical.y, physical.width, physical.height);
            }
            if (state.toolbar_dirty) {
                sandbox.toolbar(native, state.tool);
                display.badge_ui_pixels_changed_area(image, 152, 389, 164, 22);
            }
            if (state.gravity_dirty) {
                sandbox.gravityIcon(native, state.gravity.direction);
                display.badge_ui_pixels_changed_area(image, 326, 27, 26, 26);
            }
        }
        state.toolbar_dirty = false;
        state.gravity_dirty = false;
        const end_us = idf.sys.esp_timer_get_time();
        sandbox_perf_frames += 1;
        sandbox_sim_us += simulated_us - start_us;
        sandbox_paint_us += end_us - simulated_us;
        sandbox_max_us = @max(sandbox_max_us, end_us - start_us);
        if (end_us - sandbox_perf_start >= 2_000_000) {
            log.info("Sandbox: gravity={s}, ticks={d}, moves={d}, sand/water/wall={d}/{d}/{d}, avg sim={d} us, paint={d} us, max callback={d} us", .{
                @tagName(state.gravity.direction),              state.world.steps - sandbox_last_steps,           state.world.moves - sandbox_last_moves,
                state.world.counts[1],                          state.world.counts[2],                            state.world.counts[3],
                @divTrunc(sandbox_sim_us, sandbox_perf_frames), @divTrunc(sandbox_paint_us, sandbox_perf_frames), sandbox_max_us,
            });
            sandbox_perf_start = end_us;
            sandbox_perf_frames = 0;
            sandbox_sim_us = 0;
            sandbox_paint_us = 0;
            sandbox_max_us = 0;
            sandbox_last_steps = state.world.steps;
            sandbox_last_moves = state.world.moves;
        }
    } else if (full_refresh) {
        sandbox.paintFull(native, null);
        display.badge_ui_pixels_changed(image);
    }
    full_refresh = false;
}

var perf_start: i64 = 0;
var perf_frames: u32 = 0;
var perf_model_frames: u32 = 0;
var raster_us: i64 = 0;
var expand_us: i64 = 0;

fn invalidate(bounds: pixel.Region) void {
    display.badge_ui_pixels_changed_area(image, viewport.offset + bounds.x * viewport.scale, viewport.offset + bounds.y * viewport.scale, bounds.width * viewport.scale, bounds.height * viewport.scale);
}

fn draw(model_changed: bool, full: bool) void {
    if (router.active == .physics) {
        physics_service.paintFull(pixel.Canvas.init(frame, 466, 466));
        if (ready) display.badge_ui_pixels_changed(image);
        return;
    }
    if (router.active == .fluid) {
        fluid_service.paintFull(pixel.Canvas.init(frame, 466, 466));
        if (ready) display.badge_ui_pixels_changed(image);
        return;
    }
    if (router.active == .rhythm) {
        drawRhythm(full);
        return;
    }
    if (router.active == .sandbox) {
        sandbox.paintFull(pixel.Canvas.init(frame, 466, 466), if (sandbox_state) |*state| state else null);
        if (sandbox_state) |*state| _ = state.world.takeDamage();
        if (ready) display.badge_ui_pixels_changed(image);
        return;
    }
    if (router.active == .doom) {
        doom_service.paintFull(pixel.Canvas.init(frame, 466, 466));
        if (ready) display.badge_ui_pixels_changed(image);
        return;
    }
    if (router.active == .cornell) {
        trace_service.paintFull(pixel.Canvas.init(frame, cornell.display_resolution, cornell.display_resolution));
        if (ready) display.badge_ui_pixels_changed(image);
        return;
    }
    const start = idf.sys.esp_timer_get_time();
    switch (router.active) {
        .fumo => {
            if (model_changed or full) renderer.draw(canvas, render_pose, scene_ms) else renderer.drawBackdrop(canvas, render_pose, scene_ms);
            jirai.navigation(canvas, 0, navigation.demo_count, colors.accent, colors.border);
        },
        .dice => dice.draw(canvas, &dice_state, paint_ms),
        .cornell, .doom, .sandbox, .rhythm, .fluid, .physics => unreachable,
    }
    const raster_end = idf.sys.esp_timer_get_time();
    var damage: pixel.Damage = .{};
    if (full) {
        pixel.expandNearest(canvas, frame, viewport);
    } else if (router.active == .fumo) {
        const regions = model.dirtyRegions(canvas.width, canvas.height);
        if (model_changed) pixel.expandNearestRegion(canvas, frame, viewport, regions[0]);
        pixel.expandNearestRegion(canvas, frame, viewport, regions[1]);
    } else {
        damage = pixel.Damage.between(canvas, frame, viewport);
        for (damage.slice()) |region| pixel.expandNearestRegion(canvas, frame, viewport, region);
    }
    const end = idf.sys.esp_timer_get_time();
    if (ready) {
        if (full) display.badge_ui_pixels_changed(image) else if (router.active == .fumo) {
            const regions = model.dirtyRegions(canvas.width, canvas.height);
            if (model_changed) invalidate(regions[0]);
            invalidate(regions[1]);
        } else for (damage.slice()) |region| invalidate(region);
    }
    if (!ready) {
        log.info("first Fumo frame: raster={d} us, expand={d} us", .{ raster_end - start, end - raster_end });
    }
    if (perf_start == 0) perf_start = start;
    perf_frames += 1;
    if (model_changed) perf_model_frames += 1;
    raster_us += raster_end - start;
    expand_us += end - raster_end;
    if (end - perf_start >= 2_000_000) {
        log.info("scene render: {d} frames ({d} model), avg raster={d} us, expand={d} us (excludes LVGL and display transfer)", .{ perf_frames, perf_model_frames, @divTrunc(raster_us, perf_frames), @divTrunc(expand_us, perf_frames) });
        perf_start = end;
        perf_frames = 0;
        perf_model_frames = 0;
        raster_us = 0;
        expand_us = 0;
    }
}

fn simulationFrame(comptime service: type, comptime label: []const u8, perf: *CallbackPerf, now_ms: u64) void {
    const started = idf.sys.esp_timer_get_time();
    const update = service.poll(now_ms, motion.acceleration(now_ms));
    const native = pixel.Canvas.init(frame, 466, 466);
    if (full_refresh or update.full) {
        service.paintFull(native);
        display.badge_ui_pixels_changed(image);
    } else {
        service.paint(native, update);
        if (update.region) |r| display.badge_ui_pixels_changed_area(image, r.x, r.y, r.width, r.height);
    }
    full_refresh = false;
    perf.record(label, started, idf.sys.esp_timer_get_time());
}

const CallbackPerf = struct {
    start: i64 = 0,
    total: i64 = 0,
    maximum: i64 = 0,
    frames: u32 = 0,

    fn record(self: *CallbackPerf, comptime label: []const u8, started: i64, ended: i64) void {
        if (self.start == 0) self.start = started;
        self.total += ended - started;
        self.maximum = @max(self.maximum, ended - started);
        self.frames += 1;
        if (ended - self.start >= 2_000_000) {
            log.info(label ++ " UI: avg/max callback={d}/{d} us", .{ @divTrunc(self.total, self.frames), self.maximum });
            self.* = .{ .start = ended };
        }
    }
};

export fn badge_on_frame(now_ms: u64) callconv(.c) void {
    if (!ready) return;
    paint_ms = now_ms;
    if (router.active == .physics) return simulationFrame(physics_service, "Rigid", &physics_perf, now_ms);
    if (router.active == .fluid) return simulationFrame(fluid_service, "Fluid", &fluid_perf, now_ms);
    if (router.active == .rhythm) {
        rhythmFrame(now_ms);
        return;
    }
    if (router.active == .sandbox) {
        sandboxFrame(now_ms);
        return;
    }
    if (router.active == .doom) {
        const update = doom_service.poll();
        const native = pixel.Canvas.init(frame, 466, 466);
        if (full_refresh or update.full) {
            doom_service.paintFull(native);
            display.badge_ui_pixels_changed(image);
        } else if (update.frame or update.controls) {
            doom_service.paint(native, update);
            if (update.frame) {
                const r = doom.game_region;
                display.badge_ui_pixels_changed_area(image, r.x, r.y, r.width, r.height);
            }
            if (update.controls) {
                display.badge_ui_pixels_changed_area(image, 100, 342, 274, 81);
                display.badge_ui_pixels_changed_area(image, 190, 48, 86, 28);
            }
        }
        full_refresh = false;
        return;
    }
    if (router.active == .cornell) {
        const update = trace_service.poll(now_ms);
        const native = pixel.Canvas.init(frame, cornell.display_resolution, cornell.display_resolution);
        if (full_refresh or update.full) {
            trace_service.paintFull(native);
            display.badge_ui_pixels_changed(image);
        } else if (update.len > 0 or update.hud) {
            trace_service.paint(native, update);
            for (update.slice()) |region| {
                const r = cornell.physicalRegion(region);
                display.badge_ui_pixels_changed_area(image, r.x, r.y, r.width, r.height);
            }
            if (update.hud) display.badge_ui_pixels_changed_area(image, 126, 397, 214, 32);
        }
        full_refresh = false;
        return;
    }
    if (router.active == .dice) {
        const started = idf.sys.esp_timer_get_time();
        defer dice_perf.record("Dice", started, idf.sys.esp_timer_get_time());
        const was_rolling = dice_state.rolling();
        const reading: ?dice.Reading = if (motion.reading(now_ms)) |sample| .{ .accel = sample.accel, .gyro = sample.gyro, .time_ms = sample.time_ms } else null;
        if (dice_state.advance(now_ms, reading)) {
            if (dice_state.has_result) log.info("Dice settled: face={d}, impacts={d}", .{ dice_state.face, dice_state.world.collisions }) else log.info("Dice cocked against tray: tilt or tap again", .{});
        }
        if (!was_rolling and dice_state.rolling()) log.info("Dice moved by IMU", .{});
        if (now_ms -| dice_report_ms >= 2000) {
            const elapsed = @max(@as(u64, 1), now_ms -| dice_report_ms);
            log.info("Dice physics: active steps/s={d}, substeps/s={d}, sleeping={}, dropped={d} ms", .{ (dice_state.world.steps - dice_report_steps) * 1000 / elapsed, (dice_state.world.substeps - dice_report_substeps) * 1000 / elapsed, dice_state.world.sleeping, dice_state.dropped_ms });
            dice_report_ms = now_ms;
            dice_report_steps = dice_state.world.steps;
            dice_report_substeps = dice_state.world.substeps;
        }
        const period: u64 = if (dice_state.rolling() or was_rolling) dice.frame_period_ms else dice.idle_frame_period_ms;
        if (!full_refresh) {
            if (last_dice_frame_ms) |last| if (now_ms -| last < period) return;
        }
        last_dice_frame_ms = now_ms;
        draw(false, full_refresh);
        full_refresh = false;
        return;
    }
    const was_auto = animation.auto_rotate;
    const animated = animation.advance(now_ms);
    if (!was_auto and animation.auto_rotate) log.info("Fumo idle: auto rotation resumed after {d} ms", .{interaction.idle_resume_ms});
    const moved = view.advance(motion.latest(now_ms), now_ms, animation.press != null);
    const changed = animated or moved;
    render_pose = animation.pose;
    render_pose.view_yaw = view.offset.yaw;
    render_pose.view_pitch = view.offset.pitch;
    scene_ms = now_ms -| scene_start_ms;
    draw(changed, full_refresh);
    full_refresh = false;
}

export fn badge_on_pointer(event: u8, x: i32, y: i32, now_ms: u64) callconv(.c) void {
    if (!ready) return;
    const kind = std.enums.fromInt(pointer.Event, event) orelse return;
    if (kind == .down and router.owner == .content) cancelContent(now_ms);
    const px = std.math.clamp(x, 0, 465);
    const py = std.math.clamp(y, 0, 465);
    const previous_demo = router.active;
    switch (router.route(kind, x, y, now_ms)) {
        .ignore => return,
        .switched => |active| {
            animation.last_ms = now_ms;
            if (previous_demo == .rhythm) {
                rhythm_return_playing = rhythm_state.phase == .playing or rhythm_state.phase == .waiting;
                if (rhythm_return_playing) rhythm_state.phase = .paused;
                rhythm_audio.request(false, rhythm_state.song_ms) catch {};
            }
            cancelContent(now_ms);
            full_refresh = true;
            last_dice_frame_ms = null;
            dice_state.reenter(now_ms);
            dice_report_ms = now_ms;
            dice_report_steps = dice_state.world.steps;
            dice_report_substeps = dice_state.world.substeps;
            motion.setPage(active);
            trace_service.setActive(active == .cornell) catch |err| log.err("Cornell startup failed: {s}", .{@errorName(err)});
            doom_service.setActive(active == .doom) catch |err| log.err("Doom startup failed: {s}", .{@errorName(err)});
            fluid_service.setActive(active == .fluid) catch |err| log.err("Fluid startup failed: {s}", .{@errorName(err)});
            physics_service.setActive(active == .physics) catch |err| log.err("Rigid startup failed: {s}", .{@errorName(err)});
            if (active == .sandbox) startSandbox(now_ms) catch |err| log.err("Sandbox startup failed: {s}", .{@errorName(err)});
            if (active == .rhythm) startRhythm() catch |err| log.err("Orbit startup failed: {s}", .{@errorName(err)});
            log.info("Demo switched: {s}", .{@tagName(active)});
            return;
        },
        .content => {},
    }
    if (router.active == .dice) {
        if (dice_tap.pointer(kind, px, py, now_ms)) {
            rollDice(now_ms, "tap");
        }
        return;
    }
    if (router.active == .cornell) {
        if (trace_tap.pointer(kind, px, py, now_ms)) {
            trace_service.restart();
            full_refresh = true;
            log.info("Cornell accumulation restarted", .{});
        }
        return;
    }
    if (router.active == .doom) {
        doom_service.input(kind, px, py);
        return;
    }
    if (router.active == .sandbox) {
        if (sandbox_state) |*state| switch (state.input(kind, px, py, now_ms)) {
            .none => {},
            .tool_changed => log.info("Sandbox tool: {s}", .{@tagName(state.tool)}),
            .cleared => log.info("Sandbox cleared", .{}),
            .drawing => log.info("Sandbox brush started: {s}", .{@tagName(state.tool)}),
        };
        return;
    }
    if (router.active == .fluid or router.active == .rhythm or router.active == .physics) return;
    const action = animation.pointer(kind, px, py, now_ms);
    switch (action) {
        .tap => log.info("Fumo tap: spring jump at {d},{d}", .{ x, y }),
        .drag => log.info("Fumo orbit: yaw={d} deg, pitch={d} deg; manual view", .{ @as(i32, @intFromFloat(animation.pose.yaw * (180.0 / std.math.pi))), @as(i32, @intFromFloat(animation.pose.pitch * (180.0 / std.math.pi))) }),
        .none => {},
    }
}

fn rollDice(now_ms: u64, comptime source: []const u8) void {
    if (dice_state.roll(now_ms, idf.sys.esp_random())) {
        last_dice_frame_ms = null;
        log.info("Dice impulse: " ++ source, .{});
    }
}

fn cancelContent(now_ms: u64) void {
    physics_service.cancel();
    fluid_service.cancel();
    rhythm_state.cancel();
    rhythm_center_id = null;
    _ = rhythm_center.pointer(.cancel, 0, 0, now_ms);
    _ = animation.pointer(.cancel, 0, 0, now_ms);
    _ = dice_tap.pointer(.cancel, 0, 0, now_ms);
    _ = trace_tap.pointer(.cancel, 0, 0, now_ms);
    doom_service.input(.cancel, 0, 0);
    if (sandbox_state) |*state| _ = state.input(.cancel, 0, 0, now_ms);
}
