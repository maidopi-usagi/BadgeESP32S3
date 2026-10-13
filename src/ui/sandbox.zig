const std = @import("std");
const pixel = @import("pixel_canvas.zig");
const pointer = @import("pointer.zig");
const navigation = @import("navigation.zig");
const chrome = @import("tank_chrome.zig");
const theme = @import("theme.zig").colors;
pub const core = @import("../sandbox/world.zig");
pub const origin_x = chrome.origin_x;
pub const origin_y = chrome.origin_y;
pub const tick_ms = 20;
const tool_region: pixel.Region = .{ .x = 152, .y = 389, .width = 96, .height = 22 };
const clear_region: pixel.Region = .{ .x = 252, .y = 389, .width = 64, .height = 22 };
pub const Gravity = struct {
    direction: core.Direction = .down,
    filtered: [2]f32 = .{ 0, 0 },
    candidate: core.Direction = .down,
    candidate_frames: u8 = 0,
    pub fn update(self: *Gravity, accel: ?[3]f32) bool {
        const before = self.direction;
        const a = accel orelse {
            self.* = .{};
            return before != self.direction;
        };
        for (a) |value| if (!std.math.isFinite(value)) return false;
        const length2 = a[0] * a[0] + a[1] * a[1] + a[2] * a[2];
        if (length2 < 0.7 * 0.7 or length2 > 1.4 * 1.4) return false;
        // Accelerometer measures support acceleration. Screen axes are right,
        // up, toward the viewer; pixel axes are right/down.
        self.filtered[0] += (-a[0] - self.filtered[0]) * 0.45;
        self.filtered[1] += (a[1] - self.filtered[1]) * 0.45;
        const x = self.filtered[0];
        const y = self.filtered[1];
        const ax = @abs(x);
        const ay = @abs(y);
        if (ax * ax + ay * ay < 0.12 * 0.12) {
            self.candidate_frames = 0;
            return false;
        }
        const next: core.Direction = if (ay < ax * 0.4142) (if (x > 0) .right else .left) else if (ax < ay * 0.4142) (if (y > 0) .down else .up) else if (x > 0) (if (y > 0) .down_right else .up_right) else (if (y > 0) .down_left else .up_left);
        if (next != self.candidate) {
            self.candidate = next;
            self.candidate_frames = 0;
        }
        self.candidate_frames = @min(2, self.candidate_frames + 1);
        if (self.candidate_frames >= 2) self.direction = next;
        return before != self.direction;
    }
};
const Owner = enum { none, dish, tool, clear };
const Press = struct {
    owner: Owner,
    start: core.Vector,
    start_ms: u64,
    point: ?core.Vector,
    anchor: ?core.Vector,
    moved: bool = false,
    drawing: bool = false,
};
pub const Action = enum { none, tool_changed, cleared, drawing };
pub const State = struct {
    world: core.World,
    tool: core.Tool = .sand,
    gravity: Gravity = .{},
    press: ?Press = null,
    last_ms: ?u64 = null,
    remainder_ms: u64 = 0,
    toolbar_dirty: bool = true,
    gravity_dirty: bool = true,
    pub fn init(allocator: std.mem.Allocator) !State {
        return .{ .world = try core.World.init(allocator) };
    }
    pub fn deinit(self: *State) void {
        self.world.deinit();
        self.* = undefined;
    }
    pub fn reenter(self: *State, now: u64) void {
        self.last_ms = now;
        self.remainder_ms = 0;
        self.press = null;
    }
    pub fn gridPoint(self: State, x: i32, y: i32) ?core.Vector {
        if (x < origin_x or y < origin_y or x >= origin_x + core.size * 2 or y >= origin_y + core.size * 2) return null;
        const gx = @divTrunc(x - origin_x, 2);
        const gy = @divTrunc(y - origin_y, 2);
        const index = @as(usize, @intCast(gy)) * core.size + @as(usize, @intCast(gx));
        if (self.world.cells[index] & core.locked != 0) return null;
        return .{ .x = gx, .y = gy };
    }
    fn owner(self: State, x: i32, y: i32) Owner {
        if (chrome.contains(tool_region, x, y)) return .tool;
        if (chrome.contains(clear_region, x, y)) return .clear;
        return if (self.gridPoint(x, y) != null) .dish else .none;
    }
    fn drawPress(self: *State, press: *Press) void {
        if (press.point) |point| {
            if (press.anchor) |anchor| self.world.stroke(anchor, point, self.tool) else self.world.brush(point.x, point.y, self.tool);
        }
        press.anchor = press.point;
    }
    pub fn input(self: *State, event: pointer.Event, x: i32, y: i32, now: u64) Action {
        if (event == .cancel) {
            self.press = null;
            return .none;
        }
        if (event == .down) {
            const point = self.gridPoint(x, y);
            self.press = .{ .owner = self.owner(x, y), .start = .{ .x = x, .y = y }, .start_ms = now, .point = point, .anchor = point };
            return .none;
        }
        var press = self.press orelse return .none;
        const dx = x - press.start.x;
        const dy = y - press.start.y;
        press.moved = press.moved or dx * dx + dy * dy > pointer.drag_threshold * pointer.drag_threshold;
        press.point = self.gridPoint(x, y);
        const just_started = press.owner == .dish and !press.drawing and press.moved;
        if (just_started) press.drawing = true;
        if (press.drawing) self.drawPress(&press);
        if (event == .up) {
            self.press = null;
            if (!press.moved and !press.drawing and now -| press.start_ms <= pointer.tap_max_ms) {
                if (press.owner == .clear and self.owner(x, y) == .clear) {
                    self.world.clear();
                    return .cleared;
                }
                if (press.owner == .tool and self.owner(x, y) == .tool or press.owner == .dish) {
                    self.tool = @fromBackingInt(@intCast((@as(u8, @backingInt(self.tool)) + 1) % 4));
                    self.toolbar_dirty = true;
                    return .tool_changed;
                }
            }
            return if (just_started) .drawing else .none;
        }
        self.press = press;
        return if (just_started) .drawing else .none;
    }
    pub fn advance(self: *State, now: u64, accel: ?[3]f32) void {
        self.gravity_dirty = self.gravity.update(accel) or self.gravity_dirty;
        if (self.press) |*press| {
            if (press.owner == .dish and !press.drawing and now -| press.start_ms > pointer.tap_max_ms) {
                press.drawing = true;
                self.drawPress(press);
            }
        }
        const elapsed = if (self.last_ms) |last| @min(now -| last, 60) else 0;
        self.last_ms = now;
        self.remainder_ms += elapsed;
        while (self.remainder_ms >= tick_ms) : (self.remainder_ms -= tick_ms) {
            if (self.press) |press| if (press.drawing) {
                if (press.point) |point| self.world.brush(point.x, point.y, self.tool);
            };
            self.world.step(self.gravity.direction);
        }
    }
};
const colors: [64]u16 = colors: {
    var table: [64]u16 = undefined;
    for (&table, 0..) |*color, index| {
        const variation: u24 = @intCast(index >> 2);
        color.* = switch (index & 3) {
            0 => theme.surface,
            1 => pixel.rgb565((@as(u24, 166) + variation * 3) << 16 | (@as(u24, 64) + variation * 4) << 8 | (@as(u24, 111) + variation * 4)),
            2 => pixel.rgb565((@as(u24, 97) + variation * 3) << 16 | (@as(u24, 83) + variation * 3) << 8 | (@as(u24, 150) + variation * 4)),
            3 => pixel.rgb565((@as(u24, 68) + variation * 3) << 16 | (@as(u24, 49) + variation * 3) << 8 | (@as(u24, 78) + variation * 3)),
            else => unreachable,
        };
    }
    break :colors table;
};
pub fn physicalRegion(region: core.Region) pixel.Region {
    return .{ .x = origin_x + region.x * 2, .y = origin_y + region.y * 2, .width = region.width * 2, .height = region.height * 2 };
}
pub fn paintRegion(canvas: pixel.Canvas, world: core.World, region: core.Region) void {
    for (region.y..@as(usize, region.y) + region.height) |y| {
        const output = (origin_y + y * 2) * canvas.width + origin_x + region.x * 2;
        for (region.x..@as(usize, region.x) + region.width, 0..) |x, i| {
            const cell = world.cells[y * core.size + x];
            const color: u16 = if (cell & core.locked != 0) (if (core.material(cell) == .wall) (if ((x + y) & 7 == 0) theme.rose else theme.border) else theme.background) else colors[cell & 63];
            canvas.pixels[output + i * 2] = color;
            canvas.pixels[output + i * 2 + 1] = color;
        }
        @memcpy(canvas.pixels[output + canvas.width ..][0 .. @as(usize, region.width) * 2], canvas.pixels[output..][0 .. @as(usize, region.width) * 2]);
    }
}
pub fn toolbar(canvas: pixel.Canvas, tool: core.Tool) void {
    const color = switch (tool) {
        .sand => theme.rose,
        .water => theme.accent,
        .wall => theme.muted,
        .erase => theme.text,
    };
    const text = switch (tool) {
        .sand => "SAND",
        .water => "WATER",
        .wall => "WALL",
        .erase => "ERASE",
    };
    chrome.button(canvas, tool_region, text, color);
    chrome.button(canvas, clear_region, "CLEAR", theme.muted);
}
pub fn gravityIcon(canvas: pixel.Canvas, direction: core.Direction) void {
    canvas.rect(326, 27, 26, 26, theme.background);
    const g = core.vector(direction);
    const x = 339 + g.x * 9;
    const y = 40 + g.y * 9;
    canvas.line(339 - g.x * 5, 40 - g.y * 5, x, y, theme.accent);
    canvas.line(x, y, x - g.x * 4 - g.y * 3, y - g.y * 4 + g.x * 3, theme.accent);
    canvas.line(x, y, x - g.x * 4 + g.y * 3, y - g.y * 4 - g.x * 3, theme.accent);
}
pub fn paintFull(canvas: pixel.Canvas, state: ?*const State) void {
    chrome.begin(canvas, "SANDBOX", "DRAG DRAW / TAP TOOL");
    if (state) |s| {
        paintRegion(canvas, s.world, .{ .x = 0, .y = 0, .width = core.size, .height = core.size });
        toolbar(canvas, s.tool);
        gravityIcon(canvas, s.gravity.direction);
    } else canvas.centeredText("UNAVAILABLE", 215, 2, theme.accent);
    chrome.finish(canvas, 4);
}

test "absolute gravity follows screen axes, holds when flat, and rejects acceleration shocks" {
    var gravity: Gravity = .{};
    for (0..8) |_| _ = gravity.update(.{ -1, 0, 0 });
    try std.testing.expectEqual(core.Direction.right, gravity.direction);
    for (0..20) |_| _ = gravity.update(.{ 0, 0, 1 });
    try std.testing.expectEqual(core.Direction.right, gravity.direction);
    _ = gravity.update(.{ std.math.nan(f32), 0, 1 });
    _ = gravity.update(.{ 3, 0, 0 });
    try std.testing.expectEqual(core.Direction.right, gravity.direction);
    for (0..8) |_| _ = gravity.update(.{ 0, -1, 0 });
    try std.testing.expectEqual(core.Direction.up, gravity.direction);
    _ = gravity.update(null);
    try std.testing.expectEqual(core.Direction.down, gravity.direction);
}
test "sandbox taps select tools while drags and holds paint without changing tools" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();
    state.world.clear();
    _ = state.input(.down, 233, 226, 0);
    try std.testing.expectEqual(Action.tool_changed, state.input(.up, 233, 226, 100));
    try std.testing.expectEqual(core.Tool.water, state.tool);
    try std.testing.expectEqual(@as(u32, 0), state.world.counts[2]);
    _ = state.input(.down, 170, 220, 200);
    _ = state.input(.move, 295, 220, 230);
    _ = state.input(.up, 170, 220, 250);
    try std.testing.expectEqual(core.Tool.water, state.tool);
    try std.testing.expect(state.world.counts[2] > 100);
    state.world.clear();
    state.reenter(300);
    _ = state.input(.down, 233, 200, 300);
    state.advance(720, null);
    try std.testing.expect(state.world.counts[2] > 0);
    _ = state.input(.cancel, 0, 0, 730);
    const count = state.world.counts[2];
    state.advance(1000, null);
    try std.testing.expectEqual(count, state.world.counts[2]);
    _ = state.input(.down, 284, 400, 1100);
    try std.testing.expectEqual(Action.cleared, state.input(.up, 284, 400, 1150));
    try std.testing.expectEqual(@as(u32, 0), state.world.counts[2]);
}
test "sandbox partial rendering matches a full frame after painting simulation and clearing" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();
    const partial = try std.testing.allocator.alloc(u16, 466 * 466);
    defer std.testing.allocator.free(partial);
    const full = try std.testing.allocator.alloc(u16, 466 * 466);
    defer std.testing.allocator.free(full);
    paintFull(pixel.Canvas.init(partial, 466, 466), &state);
    _ = state.world.takeDamage();
    for (0..10) |i| {
        state.world.brush(@intCast(20 + i * 11), 70, .wall);
        for (0..10) |_| state.world.step(@fromBackingInt(@as(u3, @intCast(i % 8))));
        if (i == 9) state.world.clear();
        if (state.world.takeDamage()) |region| paintRegion(pixel.Canvas.init(partial, 466, 466), state.world, region);
        paintFull(pixel.Canvas.init(full, 466, 466), &state);
        try std.testing.expectEqualSlices(u16, full, partial);
    }
}
test "sandbox reentry freezes elapsed time and toolbar pixels remain in the content touch zone" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();
    state.reenter(0);
    state.advance(40, null);
    const steps = state.world.steps;
    state.reenter(20_000);
    state.advance(20_000, null);
    try std.testing.expectEqual(steps, state.world.steps);
    const frame = try std.testing.allocator.alloc(u16, 466 * 466);
    defer std.testing.allocator.free(frame);
    @memset(frame, 0);
    toolbar(pixel.Canvas.init(frame, 466, 466), .sand);
    for (frame, 0..) |color, i| if (color != 0) {
        const x: i32 = @intCast(i % 466);
        const y: i32 = @intCast(i / 466);
        try std.testing.expectEqual(navigation.Owner.content, navigation.zone(x, y));
        try std.testing.expect(state.owner(x, y) == .tool or state.owner(x, y) == .clear);
    };
}
