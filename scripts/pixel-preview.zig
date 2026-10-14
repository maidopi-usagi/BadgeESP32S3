const std = @import("std");
const demos = @import("model_renderer");
const model = demos.fumo;
const pixel = model.pixel;
const viewport = pixel.Viewport.init(@import("render_options").pixel_scale);

extern "c" fn write(fd: c_int, data: [*]const u8, count: usize) isize;
extern "c" fn _setmode(fd: c_int, mode: c_int) c_int;

fn output(bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = write(1, remaining.ptr, remaining.len);
        if (written <= 0) @panic("Could not write preview to stdout");
        remaining = remaining[@intCast(written)..];
    }
}

pub fn main() !void {
    var pixels: [viewport.logical_size * viewport.logical_size]u16 = undefined;
    const canvas = pixel.Canvas.init(&pixels, viewport.logical_size, viewport.logical_size);
    var frame: [466 * 466]u16 = undefined;
    const options = @import("preview_options");
    if (options.demo == .cornell) {
        var engine = try demos.cornell.tracer.Engine.init(std.heap.page_allocator, demos.cornell.resolution, true, 0xC04E11);
        defer engine.deinit();
        var view = try demos.cornell.View.init(std.heap.page_allocator, demos.cornell.resolution);
        defer view.deinit();
        while (engine.samples < options.samples) {
            const bucket = engine.renderNext().?;
            _ = view.accept(.{ .generation = view.generation, .bucket = bucket });
        }
        _ = view.advanceHud(1000);
        view.paint(pixel.Canvas.init(&frame, 466, 466));
    } else if (options.demo == .doom) {
        const bytes = @import("doom_preview_frame").bytes;
        if (bytes.len != demos.doom.pixel_count * 2) @compileError("Invalid Doom preview frame");
        var game: [demos.doom.pixel_count]u16 = undefined;
        for (&game, 0..) |*ink, i| ink.* = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);
        demos.doom.paintFull(pixel.Canvas.init(&frame, 466, 466), &game, 0, false);
    } else if (options.demo == .physics) {
        const world = try demos.physics.core.World.create(std.heap.page_allocator);
        defer std.heap.page_allocator.destroy(world);
        const direction = std.meta.stringToEnum(demos.sandbox.core.Direction, options.sandbox_gravity) orelse @panic("Invalid preview-gravity");
        const v = demos.sandbox.core.vector(direction);
        const length: f32 = if (v.x != 0 and v.y != 0) 0.70710678 else 1;
        const gravity: demos.physics.core.Vec = .{ .x = @as(f32, @floatFromInt(v.x)) * 300 * length, .y = @as(f32, @floatFromInt(v.y)) * 300 * length };
        for (0..options.time_ms * demos.physics.core.hz / 1000) |_| _ = world.step(gravity, &.{});
        var snapshot: demos.physics.Snapshot = .{};
        demos.physics.Snapshot.capture(world, 0, &snapshot);
        demos.physics.paintFull(pixel.Canvas.init(&frame, 466, 466), &snapshot, false);
    } else if (options.demo == .fluid) {
        var world = try demos.fluid.core.World.init(std.heap.page_allocator);
        defer world.deinit();
        const direction = std.meta.stringToEnum(demos.sandbox.core.Direction, options.sandbox_gravity) orelse @panic("Invalid preview-gravity");
        const v = demos.sandbox.core.vector(direction);
        const length: f32 = if (v.x != 0 and v.y != 0) 0.70710678 else 1;
        const gravity: demos.fluid.core.Vec = .{ .x = @as(f32, @floatFromInt(v.x)) * 120 * length, .y = @as(f32, @floatFromInt(v.y)) * 120 * length };
        for (0..options.time_ms * 120 / 1000) |_| _ = world.step(gravity, &.{});
        const snapshot = demos.fluid.Snapshot.fromWorld(&world, 0);
        demos.fluid.paintFull(pixel.Canvas.init(&frame, 466, 466), &snapshot, false);
    } else if (options.demo == .rhythm) {
        const state: demos.rhythm.game.State = if (options.time_ms == 0) .{} else .{ .phase = if (options.time_ms >= 32_000) .results else .playing, .song_ms = @intCast(@min(32_000, options.time_ms)) };
        const source = try std.heap.page_allocator.alloc(u16, 233 * 233);
        defer std.heap.page_allocator.free(source);
        const rhythm_canvas = pixel.Canvas.init(source, 233, 233);
        demos.rhythm.draw(rhythm_canvas, &state);
        pixel.expandNearest(rhythm_canvas, &frame, demos.rhythm.viewport);
    } else if (options.demo == .sandbox) {
        var state = try demos.sandbox.State.init(std.heap.page_allocator);
        defer state.deinit();
        const gravity = std.meta.stringToEnum(demos.sandbox.core.Direction, options.sandbox_gravity) orelse @panic("Invalid preview-gravity");
        state.gravity.direction = gravity;
        for (0..options.time_ms / demos.sandbox.tick_ms) |_| state.world.step(gravity);
        demos.sandbox.paintFull(pixel.Canvas.init(&frame, 466, 466), &state);
    } else if (options.demo == .dice) {
        var dice: demos.dice.State = .{};
        dice.reenter(0);
        if (options.roll_ms) |elapsed| {
            _ = dice.roll(0, options.dice_seed);
            var time: u64 = 8;
            while (time < elapsed) : (time += 8) _ = dice.advance(time, null);
            _ = dice.advance(elapsed, null);
            demos.dice.draw(canvas, &dice, elapsed);
        } else demos.dice.draw(canvas, &dice, options.time_ms);
    } else {
        const renderer = try model.Renderer.init(std.heap.page_allocator, viewport.logical_size, viewport.logical_size);
        defer renderer.deinit();
        var motion: model.interaction.State = .{};
        motion.pose.yaw = @as(f32, @floatFromInt(options.time_ms % 18000)) * (2 * std.math.pi / 18000.0);
        motion.pose.pitch = std.math.clamp(options.pitch, -0.55, 0.85);
        if (options.bounce_ms) |bounce_ms| {
            motion.auto_rotate = false;
            _ = motion.advance(0);
            motion.bounce();
            var time: u64 = 8;
            while (time < bounce_ms) : (time += 8) _ = motion.advance(time);
            _ = motion.advance(bounce_ms);
        }
        renderer.draw(canvas, motion.pose, options.time_ms);
        demos.jirai.navigation(canvas, 0, demos.navigation.demo_count, demos.colors.accent, demos.colors.border);
    }
    if (options.demo == .fumo or options.demo == .dice) pixel.expandNearest(canvas, &frame, viewport);
    const battery_mode = std.meta.stringToEnum(demos.battery.Mode, options.battery_mode).?;
    demos.battery.composite(pixel.Canvas.init(&frame, 466, 466), .{
        .mode = battery_mode,
        .percent = if (battery_mode == .unknown or battery_mode == .absent) null else options.battery_percent,
    }, options.time_ms);
    if (@import("builtin").os.tag == .windows) _ = _setmode(1, 0x8000);
    output("P6\n466 466\n255\n");
    var row: [466 * 3]u8 = undefined;
    for (0..466) |y| {
        for (0..466) |x| {
            const color = frame[y * 466 + x];
            row[x * 3] = @intCast(@as(u32, (color >> 11) & 31) * 255 / 31);
            row[x * 3 + 1] = @intCast(@as(u32, (color >> 5) & 63) * 255 / 63);
            row[x * 3 + 2] = @intCast(@as(u32, color & 31) * 255 / 31);
        }
        output(&row);
    }
}
