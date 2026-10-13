const std = @import("std");
pub const core = @import("../physics/world.zig");
const pixel = @import("pixel_canvas.zig");
const pointer = @import("pointer.zig");
const chrome = @import("tank_chrome.zig");
const theme = @import("theme.zig").colors;
pub const Gravity = @import("fluid.zig").Gravity;
pub const origin_x = chrome.origin_x;
pub const origin_y = chrome.origin_y;
const background = theme.surface;
const colors = [_]u16{ theme.accent, theme.rose, pixel.rgb565(0xA56C99), pixel.rgb565(0x7B718F), pixel.rgb565(0xC3AACF), pixel.rgb565(0x985775) };
pub const Pose = struct { position: core.Vec, rotation: core.Vec, half: f32, shape: core.Shape };
pub const Snapshot = struct {
    generation: u32 = 0,
    count: u8 = 0,
    poses: [core.max_bodies]Pose = undefined,
    pub fn capture(world: *const core.World, generation: u32, result: *Snapshot) void {
        result.generation = generation;
        result.count = world.count;
        for (world.bodies[0..world.count], 0..) |b, i| result.poses[i] = .{ .position = b.position, .rotation = b.rotation, .half = b.half, .shape = b.shape };
    }
};
const Press = struct { body: ?u8 = null, reset: bool = false, tap: pointer.Tap = .{}, local: core.Vec = .{}, point: core.Vec, velocity: core.Vec = .{}, moved_ms: u64 };
pub const Controller = struct {
    presses: [16]?Press = @splat(null),
    generation: u32 = 0,
    pub fn cancel(self: *Controller) void {
        self.presses = @splat(null);
    }
    fn point(x: i32, y: i32) core.Vec {
        return .{ .x = @as(f32, @floatFromInt(x - origin_x)) * 0.5, .y = @as(f32, @floatFromInt(y - origin_y)) * 0.5 };
    }
    fn resetHit(x: i32, y: i32) bool {
        return chrome.contains(chrome.reset_region, x, y);
    }
    pub fn input(self: *Controller, kind: pointer.Event, id: u8, x: i32, y: i32, now: u64, snapshot: ?*const Snapshot) bool {
        if (id >= self.presses.len) return false;
        if (kind == .cancel) {
            self.presses[id] = null;
            return false;
        }
        const p = point(x, y);
        if (kind == .down) {
            var press: Press = .{ .point = p, .moved_ms = now, .reset = resetHit(x, y) };
            _ = press.tap.pointer(kind, x, y, now);
            if (!press.reset) if (snapshot) |source| {
                var i: usize = source.count;
                while (i > 0) {
                    i -= 1;
                    var held = false;
                    for (self.presses) |contact| if (contact) |other| if (other.body) |held_body| if (held_body == i) {
                        held = true;
                    };
                    if (held) continue;
                    const body = source.poses[i];
                    const local = core.unrotate(body.rotation, p.sub(body.position));
                    const inside = if (body.shape == .ball) local.length2() <= body.half * body.half else @abs(local.x) <= body.half and @abs(local.y) <= body.half;
                    if (!inside) continue;
                    press.body = @intCast(i);
                    press.local = local;
                    break;
                }
            };
            self.presses[id] = press;
            return false;
        }
        var press = self.presses[id] orelse return false;
        const tapped = press.tap.pointer(kind, x, y, now);
        const delta = p.sub(press.point);
        const elapsed = now -| press.moved_ms;
        if (elapsed > 0 and delta.length2() > 0) {
            var v = delta.scale(1000 / @as(f32, @floatFromInt(elapsed)));
            if (v.length2() > 260 * 260) v = v.scale(260 / @sqrt(v.length2()));
            press.velocity = if (elapsed > 80) v else press.velocity.scale(0.25).add(v.scale(0.75));
            press.moved_ms = now;
        }
        press.point = p;
        if (kind == .up) {
            self.presses[id] = null;
            if (press.reset and tapped and resetHit(x, y)) {
                self.generation +%= 1;
                self.cancel();
                return true;
            }
        } else self.presses[id] = press;
        return false;
    }
    pub fn grabs(self: *const Controller, now: u64) core.Grabs {
        var result: core.Grabs = .{};
        for (self.presses) |contact| if (contact) |press| if (press.body) |body| {
            if (result.count == result.items.len) break;
            var target = press.point;
            const radial = target.sub(core.center);
            if (radial.length2() > 68 * 68) target = core.center.add(radial.scale(68 / @sqrt(radial.length2())));
            result.items[result.count] = .{ .body = body, .local = press.local, .target = target, .velocity = if (now -| press.moved_ms < 80) press.velocity else .{} };
            result.count += 1;
        };
        return result;
    }
};
pub const Clock = @import("../simulation/clock.zig").Clock(core.hz, 8);
const Visual = struct { shape: core.Shape, x: i32, y: i32, radius: i32, corners: [4][2]i32, tip: [2]i32 };
fn coordinate(v: core.Vec) [2]i32 {
    return .{ origin_x + @as(i32, @intFromFloat(@round(v.x * 2))), origin_y + @as(i32, @intFromFloat(@round(v.y * 2))) };
}
fn visual(p: Pose) Visual {
    const c = coordinate(p.position);
    var result: Visual = .{ .shape = p.shape, .x = c[0], .y = c[1], .radius = @intFromFloat(p.half * 2), .corners = undefined, .tip = coordinate(p.position.add(p.rotation.scale(p.half * 0.65))) };
    const x = p.rotation.scale(p.half);
    const y: core.Vec = .{ .x = -p.rotation.y * p.half, .y = p.rotation.x * p.half };
    for ([_]core.Vec{ p.position.sub(x).sub(y), p.position.add(x).sub(y), p.position.add(x).add(y), p.position.sub(x).add(y) }, 0..) |v, i| result.corners[i] = coordinate(v);
    return result;
}
fn same(a: Visual, b: Visual) bool {
    if (a.shape != b.shape or a.x != b.x or a.y != b.y or a.tip[0] != b.tip[0] or a.tip[1] != b.tip[1]) return false;
    if (a.shape == .ball) return a.radius == b.radius;
    return std.mem.eql([2]i32, &a.corners, &b.corners);
}
fn bounds(v: Visual) [4]i32 {
    if (v.shape == .ball) return .{ v.x - v.radius, v.y - v.radius, v.x + v.radius + 1, v.y + v.radius + 1 };
    var b = [_]i32{ 466, 466, 0, 0 };
    for (v.corners) |p| {
        b[0] = @min(b[0], p[0]);
        b[1] = @min(b[1], p[1]);
        b[2] = @max(b[2], p[0] + 1);
        b[3] = @max(b[3], p[1] + 1);
    }
    return b;
}
pub fn damage(before: *const Snapshot, after: *const Snapshot) ?pixel.Region {
    var region = [_]i32{ 466, 466, 0, 0 };
    for (0..@max(before.count, after.count)) |i| {
        if (i < before.count and i < after.count and same(visual(before.poses[i]), visual(after.poses[i]))) continue;
        for (0..2) |side| {
            const source = if (side == 0) before else after;
            if (i >= source.count) continue;
            const b = bounds(visual(source.poses[i]));
            region[0] = @min(region[0], b[0]);
            region[1] = @min(region[1], b[1]);
            region[2] = @max(region[2], b[2]);
            region[3] = @max(region[3], b[3]);
        }
    }
    if (region[0] == 466) return null;
    return .{ .x = @intCast(region[0]), .y = @intCast(region[1]), .width = @intCast(region[2] - region[0]), .height = @intCast(region[3] - region[1]) };
}
fn quad(canvas: pixel.Canvas, points: [4][2]i32, color: u16) void {
    var min_y: i32 = 466;
    var max_y: i32 = 0;
    const Edge = struct { y0: i32, y1: i32, x: i32, slope: i32 };
    var edges: [4]Edge = undefined;
    var count: usize = 0;
    for (points, 0..) |p, i| {
        var a = p;
        var b = points[(i + 1) % 4];
        if (a[1] == b[1]) continue;
        if (a[1] > b[1]) std.mem.swap([2]i32, &a, &b);
        edges[count] = .{ .y0 = a[1], .y1 = b[1], .x = a[0] * 65536, .slope = @divTrunc((b[0] - a[0]) * 65536, b[1] - a[1]) };
        count += 1;
        min_y = @min(min_y, a[1]);
        max_y = @max(max_y, b[1]);
    }
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var lo: i32 = std.math.maxInt(i32);
        var hi: i32 = std.math.minInt(i32);
        for (edges[0..count]) |edge| if (y >= edge.y0 and y <= edge.y1) {
            const x = (edge.x + edge.slope * (y - edge.y0)) >> 16;
            lo = @min(lo, x);
            hi = @max(hi, x);
        };
        if (lo <= hi) canvas.rect(lo, y, hi - lo + 1, 1, color);
    }
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % 4];
        canvas.line(p[0], p[1], q[0], q[1], color);
    }
}
fn paintBody(canvas: pixel.Canvas, v: Visual, index: usize, erase: bool) void {
    const color = if (erase) background else colors[index % colors.len];
    if (v.shape == .ball) {
        canvas.circle(v.x, v.y, v.radius, if (erase) background else theme.border);
        if (!erase) {
            canvas.circle(v.x, v.y, v.radius - 1, color);
            canvas.circle(v.x - @divTrunc(v.radius, 3), v.y - @divTrunc(v.radius, 3), @divTrunc(v.radius, 4), theme.highlight);
        }
    } else {
        quad(canvas, v.corners, color);
        if (!erase) for (v.corners, 0..) |p, i| {
            const q = v.corners[(i + 1) % 4];
            canvas.line(p[0], p[1], q[0], q[1], theme.border);
        };
    }
    if (!erase) canvas.line(v.x, v.y, v.tip[0], v.tip[1], theme.border);
}
pub fn paintChanges(canvas: pixel.Canvas, before: *const Snapshot, after: *const Snapshot) void {
    for (before.poses[0..before.count], 0..) |p, i| if (i >= after.count or !same(visual(p), visual(after.poses[i]))) paintBody(canvas, visual(p), i, true);
    for (after.poses[0..after.count], 0..) |p, i| paintBody(canvas, visual(p), i, false);
}
pub fn paintFull(canvas: pixel.Canvas, snapshot: ?*const Snapshot, failed: bool) void {
    chrome.begin(canvas, "RIGID TOYS", "TILT + THROW / TWO FINGERS");
    chrome.tank(canvas);
    if (snapshot) |s| {
        for (s.poses[0..s.count], 0..) |p, i| paintBody(canvas, visual(p), i, false);
    } else canvas.centeredText(if (failed) "UNAVAILABLE" else "FILLING", 215, 2, theme.accent);
    chrome.reset(canvas);
    chrome.finish(canvas, 7);
}
test "Rigid controller owns separate bodies and stationary reports preserve throw velocity" {
    const world = try core.World.create(std.testing.allocator);
    defer std.testing.allocator.destroy(world);
    var snapshot: Snapshot = .{};
    Snapshot.capture(world, 0, &snapshot);
    var c: Controller = .{};
    _ = c.input(.down, 3, 143, 152, 0, &snapshot);
    _ = c.input(.down, 7, 179, 152, 0, &snapshot);
    try std.testing.expectEqual(@as(u8, 2), c.grabs(0).count);
    _ = c.input(.move, 3, 163, 160, 20, &snapshot);
    const v = c.grabs(20).items[0].velocity;
    _ = c.input(.move, 3, 163, 160, 40, &snapshot);
    try std.testing.expectEqual(v, c.grabs(40).items[0].velocity);
    _ = c.input(.up, 3, 163, 160, 60, &snapshot);
    try std.testing.expectEqual(@as(u8, 1), c.grabs(60).count);
    _ = c.input(.down, 2, 233, 400, 100, &snapshot);
    try std.testing.expect(c.input(.up, 2, 233, 400, 140, &snapshot));
    try std.testing.expectEqual(@as(u8, 0), c.grabs(140).count);
}
test "Rigid incremental circles and rotated boxes exactly match a full redraw" {
    const world = try core.World.create(std.testing.allocator);
    defer std.testing.allocator.destroy(world);
    var before: Snapshot = .{};
    Snapshot.capture(world, 0, &before);
    const partial = try std.testing.allocator.alloc(u16, 466 * 466);
    defer std.testing.allocator.free(partial);
    const full = try std.testing.allocator.alloc(u16, 466 * 466);
    defer std.testing.allocator.free(full);
    paintFull(pixel.Canvas.init(partial, 466, 466), &before, false);
    for (0..20) |_| _ = world.step(.{ .y = 300 }, &.{});
    var after: Snapshot = .{};
    Snapshot.capture(world, 0, &after);
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
}
