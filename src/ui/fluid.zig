const std = @import("std");
const pixel = @import("pixel_canvas.zig");
const pointer = @import("pointer.zig");
const navigation = @import("navigation.zig");
const chrome = @import("tank_chrome.zig");
const colors = @import("theme.zig").colors;
pub const core = @import("../fluid/reintegration.zig");
pub const origin_x = chrome.origin_x;
pub const origin_y = chrome.origin_y;
const water_background = colors.surface;
pub const Gravity = struct {
    vector: core.Vec = .{ .y = 120 },
    filtered: core.Vec = .{},
    pub fn update(self: *Gravity, accel: ?[3]f32) void {
        const a = accel orelse {
            self.* = .{};
            return;
        };
        for (a) |v| if (!std.math.isFinite(v)) return;
        const length2 = a[0] * a[0] + a[1] * a[1] + a[2] * a[2];
        if (length2 < 0.7 * 0.7 or length2 > 1.4 * 1.4) return;
        self.filtered.x += (-a[0] - self.filtered.x) * 0.3;
        self.filtered.y += (a[1] - self.filtered.y) * 0.3;
        const r2 = self.filtered.length2();
        self.vector = if (r2 < 0.05 * 0.05) .{} else self.filtered.scale(120);
    }
};
const Owner = enum { none, dish, reset };
const Press = struct { owner: Owner, tap: pointer.Tap = .{}, point: core.Vec, anchor: core.Vec, velocity: core.Vec = .{}, motion_ms: u64, anchor_ms: u64 };
pub const Action = enum { none, reset };
pub const Brushes = struct { items: [5]core.Brush = undefined, count: u8 = 0 };
pub const Controller = struct {
    presses: [16]?Press = @splat(null),
    generation: u32 = 0,
    pub fn cancel(self: *Controller) void {
        self.presses = @splat(null);
    }
    fn point(x: i32, y: i32) core.Vec {
        return .{ .x = @as(f32, @floatFromInt(x - origin_x)) * 0.5, .y = @as(f32, @floatFromInt(y - origin_y)) * 0.5 };
    }
    fn owner(x: i32, y: i32) Owner {
        if (chrome.contains(chrome.reset_region, x, y)) return .reset;
        return if (point(x, y).sub(core.center).length2() < 74 * 74) .dish else .none;
    }
    pub fn input(self: *Controller, kind: pointer.Event, id: u8, x: i32, y: i32, now: u64) Action {
        if (id >= self.presses.len) return .none;
        if (kind == .cancel) {
            self.presses[id] = null;
            return .none;
        }
        if (kind == .down) {
            self.presses[id] = .{ .owner = owner(x, y), .point = point(x, y), .anchor = point(x, y), .motion_ms = now, .anchor_ms = now };
            _ = self.presses[id].?.tap.pointer(kind, x, y, now);
            return .none;
        }
        var press = self.presses[id] orelse return .none;
        const tapped = press.tap.pointer(kind, x, y, now);
        const p = point(x, y);
        const delta = p.sub(press.point);
        const elapsed = now -| press.motion_ms;
        if (delta.length2() > 0 and elapsed > 0) {
            var velocity = delta.scale(1000 / @as(f32, @floatFromInt(elapsed)));
            const speed2 = velocity.length2();
            if (speed2 > 180 * 180) velocity = velocity.scale(180 / @sqrt(speed2));
            if (elapsed > 80) press.velocity = velocity else press.velocity = press.velocity.scale(0.35).add(velocity.scale(0.65));
            if (now -| press.anchor_ms > 50) {
                press.anchor = press.point;
                press.anchor_ms = press.motion_ms;
            }
            press.motion_ms = now;
        }
        press.point = p;
        if (kind == .up) {
            self.presses[id] = null;
            if (tapped and press.owner == .reset and owner(x, y) == .reset) {
                self.generation +%= 1;
                self.cancel();
                return .reset;
            }
        } else self.presses[id] = press;
        return .none;
    }
    pub fn brushes(self: *const Controller, now: u64) Brushes {
        var result: Brushes = .{};
        for (self.presses) |contact| if (contact) |press| {
            if (press.owner != .dish or press.point.sub(core.center).length2() > 74 * 74) continue;
            if (result.count == result.items.len) break;
            const moving = now -| press.motion_ms <= 80;
            result.items[result.count] = .{ .position = press.point, .velocity = if (moving) press.velocity else .{}, .from = if (moving) press.anchor else press.point };
            result.count += 1;
        };
        return result;
    }
};
pub const Clock = @import("../simulation/clock.zig").Clock(120, 2);
pub const Dot = struct { x: u8 = 0, y: u8 = 0, shade: u8 = 0 };
pub const Snapshot = struct {
    generation: u32 = 0,
    count: u16 = 0,
    dots: [core.max_particles]Dot = undefined,
    pub fn fromWorld(world: *const core.World, generation: u32) Snapshot {
        var result: Snapshot = undefined;
        capture(world, generation, &result);
        return result;
    }
    pub fn capture(world: *const core.World, generation: u32, result: *Snapshot) void {
        result.generation = generation;
        result.count = 0;
        const inverse_reference = 1 / world.reference_mass;
        for (world.particles) |p| {
            if (p.density < 0.05) continue;
            const opacity = @min(1, p.density * inverse_reference);
            result.dots[result.count] = .{ .x = @intFromFloat(p.position.x + 0.5), .y = @intFromFloat(p.position.y + 0.5), .shade = @intFromFloat(@min(255, 128 + p.velocity.length2() * 0.02) * opacity) };
            result.count += 1;
        }
    }
};
const palette: [256]u16 = blk: {
    var table: [256]u16 = undefined;
    for (&table, 0..) |*v, i| {
        const shade: u32 = @intCast(i);
        const a: u32 = water_background;
        const b: u32 = colors.highlight;
        const r = ((a >> 11) * (255 - shade) + (b >> 11) * shade) / 255;
        const g = (((a >> 5) & 63) * (255 - shade) + ((b >> 5) & 63) * shade) / 255;
        const blue = ((a & 31) * (255 - shade) + (b & 31) * shade) / 255;
        v.* = @intCast(r << 11 | g << 5 | blue);
    }
    break :blk table;
};
fn dot(canvas: pixel.Canvas, p: Dot, color: u16) void {
    const x = origin_x + @as(i32, p.x) * 2;
    const y = origin_y + @as(i32, p.y) * 2;
    canvas.pixel(x - 1, y - 2, color);
    canvas.pixel(x + 2, y - 2, color);
    canvas.rect(x - 2, y - 1, 6, 2, color);
    canvas.rect(x - 1, y + 1, 4, 1, color);
    canvas.rect(x, y + 2, 2, 2, color);
}
fn same(a: Dot, b: Dot) bool {
    return a.x == b.x and a.y == b.y and a.shade == b.shade;
}
pub fn damage(before: *const Snapshot, after: *const Snapshot) ?pixel.Region {
    var x0: i32 = 466;
    var y0: i32 = 466;
    var x1: i32 = 0;
    var y1: i32 = 0;
    for (0..@max(before.count, after.count)) |i| {
        if (i < before.count and i < after.count and same(before.dots[i], after.dots[i])) continue;
        for (0..2) |which| {
            const s = if (which == 0) before else after;
            if (i >= s.count) continue;
            const p = s.dots[i];
            const x = origin_x + @as(i32, p.x) * 2;
            const y = origin_y + @as(i32, p.y) * 2;
            x0 = @min(x0, x - 2);
            y0 = @min(y0, y - 2);
            x1 = @max(x1, x + 4);
            y1 = @max(y1, y + 4);
        }
    }
    if (x0 == 466) return null;
    return .{ .x = @intCast(x0), .y = @intCast(y0), .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) };
}
pub fn paintParticles(canvas: pixel.Canvas, source: *const Snapshot) void {
    for (source.dots[0..source.count]) |p| dot(canvas, p, palette[p.shade]);
}
pub fn paintChanges(canvas: pixel.Canvas, before: *const Snapshot, after: *const Snapshot) void {
    for (before.dots[0..before.count], 0..) |p, i| if (i >= after.count or !same(p, after.dots[i])) dot(canvas, p, water_background);
    // Erasure may cover an unmoved neighbor. Redraw all in stable order.
    paintParticles(canvas, after);
}
pub fn paintFull(canvas: pixel.Canvas, source: ?*const Snapshot, failed: bool) void {
    chrome.begin(canvas, "RT FLUID", "TILT + STIR / TWO FINGERS");
    chrome.tank(canvas);
    if (source) |s| paintParticles(canvas, s) else canvas.centeredText(if (failed) "UNAVAILABLE" else "FILLING", 215, 2, colors.accent);
    chrome.reset(canvas);
    chrome.finish(canvas, 6);
}
test "Fluid controls keep two finger ownership, expire motion and isolate reset" {
    var c: Controller = .{};
    _ = c.input(.down, 7, 200, 226, 0);
    _ = c.input(.down, 3, 260, 226, 0);
    _ = c.input(.move, 7, 230, 230, 30);
    try std.testing.expectEqual(@as(u8, 2), c.brushes(30).count);
    try std.testing.expect(c.brushes(30).items[1].velocity.length2() > 0);
    try std.testing.expectEqual(@as(f32, 0), c.brushes(120).items[1].velocity.length2());
    _ = c.input(.up, 3, 260, 226, 125);
    try std.testing.expectEqual(@as(u8, 1), c.brushes(125).count);
    _ = c.input(.move, 7, 230, 400, 130);
    try std.testing.expectEqual(Action.none, c.input(.up, 7, 230, 400, 140));
    try std.testing.expectEqual(@as(u32, 0), c.generation);
    _ = c.input(.down, 1, 233, 400, 200);
    try std.testing.expectEqual(Action.reset, c.input(.up, 1, 233, 400, 260));
    try std.testing.expectEqual(@as(u32, 1), c.generation);
    try std.testing.expectEqual(@as(u8, 0), c.brushes(340).count);
}
test "Fluid stationary reports preserve real drag velocity but cannot keep stale motion alive" {
    var c: Controller = .{};
    _ = c.input(.down, 1, 193, 226, 0);
    _ = c.input(.move, 1, 213, 226, 20);
    const moving = c.brushes(20).items[0];
    _ = c.input(.move, 1, 213, 226, 21);
    _ = c.input(.move, 1, 213, 226, 35);
    try std.testing.expectEqual(moving.velocity, c.brushes(35).items[0].velocity);
    try std.testing.expect(c.brushes(35).items[0].from.?.x < moving.position.x);
    try std.testing.expectEqual(@as(f32, 0), c.brushes(101).items[0].velocity.length2());
    _ = c.input(.cancel, 1, 0, 0, 102);
    try std.testing.expectEqual(@as(u8, 0), c.brushes(102).count);
}
test "Fluid gravity is continuous in screen axes and rejects shocks and nonfinite input" {
    var g: Gravity = .{};
    for (0..40) |_| g.update(.{ -0.6, -0.8, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 72), g.vector.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -96), g.vector.y, 0.01);
    const before = g.vector;
    g.update(.{ std.math.nan(f32), 0, 1 });
    g.update(.{ 3, 0, 0 });
    try std.testing.expectEqual(before, g.vector);
    for (0..40) |_| g.update(.{ 0, 0, 1 });
    try std.testing.expectEqual(core.Vec{}, g.vector);
    for (0..40) |_| g.update(.{ -0.2, 0.3, 0.932738 });
    try std.testing.expectApproxEqAbs(@as(f32, 24), g.vector.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 36), g.vector.y, 0.01);
    g.update(null);
    try std.testing.expectEqual(@as(f32, 120), g.vector.y);
}
test "Fluid point snapshots remain inside the dish and RESET pixels are reachable" {
    var world = try core.World.init(std.testing.allocator);
    defer world.deinit();
    const source = Snapshot.fromWorld(&world, 7);
    try std.testing.expect(source.count >= 250 and source.count <= core.max_particles);
    try std.testing.expect(@sizeOf(Snapshot) < 3100);
    for (source.dots[0..source.count]) |p| {
        const dx = @as(i32, p.x) - 80;
        const dy = @as(i32, p.y) - 80;
        try std.testing.expect(dx * dx + dy * dy < 73 * 73);
    }
    for (389..411) |y| for (194..272) |x| try std.testing.expectEqual(navigation.Owner.content, navigation.zone(@intCast(x), @intCast(y)));
}
test "Fluid incremental erasure matches a full frame with overlapping and changing dot counts" {
    const full = try std.testing.allocator.alloc(u16, 466 * 466);
    defer std.testing.allocator.free(full);
    const partial = try std.testing.allocator.alloc(u16, 466 * 466);
    defer std.testing.allocator.free(partial);
    var before: Snapshot = .{ .count = 3 };
    before.dots[0] = .{ .x = 80, .y = 80, .shade = 100 };
    before.dots[1] = .{ .x = 81, .y = 80, .shade = 120 };
    before.dots[2] = .{ .x = 90, .y = 80, .shade = 255 };
    var after = before;
    after.dots[0].x = 75;
    after.dots[2].shade = 0;
    paintFull(pixel.Canvas.init(partial, 466, 466), &before, false);
    const r = damage(&before, &after).?;
    const original = try std.testing.allocator.dupe(u16, partial);
    defer std.testing.allocator.free(original);
    paintChanges(pixel.Canvas.init(partial, 466, 466), &before, &after);
    paintFull(pixel.Canvas.init(full, 466, 466), &after, false);
    try std.testing.expectEqualSlices(u16, full, partial);
    for (original, partial, 0..) |a, b, i| if (a != b) {
        const x = i % 466;
        const y = i / 466;
        try std.testing.expect(x >= r.x and x < @as(usize, r.x) + r.width and y >= r.y and y < @as(usize, r.y) + r.height);
    };
    try std.testing.expect(damage(&after, &after) == null);
    before = after;
    after.count = 2;
    after.dots[0] = before.dots[1];
    after.dots[1] = before.dots[2];
    paintChanges(pixel.Canvas.init(partial, 466, 466), &before, &after);
    paintFull(pixel.Canvas.init(full, 466, 466), &after, false);
    try std.testing.expectEqualSlices(u16, full, partial);
    before = after;
    after.count = 3;
    after.dots[2] = .{ .x = 82, .y = 84, .shade = 200 };
    paintChanges(pixel.Canvas.init(partial, 466, 466), &before, &after);
    paintFull(pixel.Canvas.init(full, 466, 466), &after, false);
    try std.testing.expectEqualSlices(u16, full, partial);
}
