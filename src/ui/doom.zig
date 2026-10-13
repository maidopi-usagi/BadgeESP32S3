const std = @import("std");
const pixel = @import("pixel_canvas.zig");
const pointer = @import("pointer.zig");
const navigation = @import("navigation.zig");
const jirai = @import("jirai.zig");
const colors = @import("theme.zig").colors;
pub const width = 320;
pub const height = 200;
pub const pixel_count = width * height;
pub const game_region: pixel.Region = .{ .x = 73, .y = 90, .width = 320, .height = 240 };
pub const key_codes = [_]u8{ 0xad, 0xaf, 0xac, 0xae, 0xa3, 0xa2, 13, 27 };
pub const up: u16 = 1;
pub const down: u16 = 2;
pub const left: u16 = 4;
pub const right: u16 = 8;
pub const fire: u16 = 16;
pub const use: u16 = 32;
pub const enter: u16 = 64;
pub const menu: u16 = 128;

const Zone = enum { none, pad, fire, use, enter, menu };
fn zone(x: i32, y: i32) Zone {
    if (x >= 125 and x < 222 and y >= 342 and y < 416) return .pad;
    if (x >= 246 and x < 306 and y >= 345 and y < 383) return .fire;
    if (x >= 310 and x < 360 and y >= 345 and y < 383) return .use;
    if (x >= 239 and x < 315 and y >= 387 and y < 413) return .enter;
    if (x >= 190 and x < 276 and y >= 48 and y < 76) return .menu;
    return .none;
}
pub const Controller = struct {
    owner: Zone = .none,
    keys: u16 = 0,
    pub fn input(self: *Controller, event: pointer.Event, x: i32, y: i32) bool {
        const old = self.keys;
        switch (event) {
            .down => self.owner = zone(x, y),
            .up, .cancel => self.owner = .none,
            .move => {},
        }
        self.keys = 0;
        if (self.owner != .none and zone(x, y) == self.owner) {
            self.keys = switch (self.owner) {
                .pad => (if (x < 160) left else if (x > 186) right else @as(u16, 0)) |
                    (if (y < 369) up else if (y >= 389) down else @as(u16, 0)),
                .fire => fire,
                .use => use,
                .enter => enter,
                .menu => menu,
                .none => 0,
            };
        }
        return old != self.keys;
    }
};

pub const Keys = struct {
    emitted: u16 = 0,
    pub const Event = struct { pressed: bool, code: u8 };
    pub fn next(self: *Keys, desired: u16) ?Event {
        const released = self.emitted & ~desired;
        const pressed = desired & ~self.emitted;
        const changed = if (released != 0) released else pressed;
        if (changed == 0) return null;
        const bit: u4 = @intCast(@ctz(changed));
        self.emitted ^= @as(u16, 1) << bit;
        return .{ .pressed = released == 0, .code = key_codes[bit] };
    }
};

pub const Clock = struct {
    epoch_ms: u64,
    paused_ms: u64 = 0,
    paused_at: ?u64 = null,
    pub fn setActive(self: *Clock, active: bool, now: u64) void {
        if (!active and self.paused_at == null) self.paused_at = now;
        if (active) if (self.paused_at) |since| {
            self.paused_ms += now -| since;
            self.paused_at = null;
        };
    }
    pub fn ticks(self: Clock, now: u64) u32 {
        return @truncate((self.paused_at orelse now) -| self.epoch_ms -| self.paused_ms + 1);
    }
};

pub fn paintGame(canvas: pixel.Canvas, pixels: []const u16) void {
    std.debug.assert(pixels.len == pixel_count);
    for (0..game_region.height) |y| {
        const source = y * height / game_region.height * width;
        const dest = (y + game_region.y) * canvas.width + game_region.x;
        @memcpy(canvas.pixels[dest..][0..width], pixels[source..][0..width]);
    }
}
fn button(canvas: pixel.Canvas, x: i32, y: i32, w: i32, h: i32, text: []const u8, held: bool) void {
    canvas.rect(x, y, w, h, colors.background);
    canvas.rect(x + 2, y, w - 4, h, if (held) colors.rose else colors.border);
    canvas.rect(x, y + 2, w, h - 4, if (held) colors.rose else colors.border);
    canvas.rect(x + 2, y + 2, w - 4, h - 4, if (held) colors.berry else colors.panel);
    const text_width: i32 = @intCast(text.len * 12 - 2);
    canvas.text(text, x + @divTrunc(w - text_width, 2), y + @divTrunc(h - 14, 2), 2, if (held) colors.highlight else colors.muted);
}
pub fn controls(canvas: pixel.Canvas, keys: u16) void {
    button(canvas, 192, 50, 82, 24, "MENU", keys & menu != 0);
    button(canvas, 160, 344, 26, 25, "U", keys & up != 0);
    button(canvas, 160, 389, 26, 25, "D", keys & down != 0);
    button(canvas, 127, 369, 26, 25, "L", keys & left != 0);
    button(canvas, 194, 369, 26, 25, "R", keys & right != 0);
    button(canvas, 248, 347, 54, 34, "FIRE", keys & fire != 0);
    button(canvas, 312, 347, 46, 34, "USE", keys & use != 0);
    button(canvas, 241, 389, 72, 22, "OK", keys & enter != 0);
}
pub fn paintFull(canvas: pixel.Canvas, pixels: ?[]const u16, keys: u16, failed: bool) void {
    canvas.clear(colors.background);
    canvas.centeredText("DOOM", 22, 3, colors.text);
    const ornament: jirai.Painter = .{ .canvas = canvas, .k = 2 };
    ornament.sparkle(87, 16, true, colors.berry);
    ornament.sparkle(145, 16, true, colors.berry);
    canvas.rect(69, 86, 328, 248, colors.border);
    canvas.rect(71, 88, 324, 244, colors.panel);
    canvas.rect(game_region.x, game_region.y, game_region.width, game_region.height, colors.background);
    var lace_y: i32 = 104;
    while (lace_y < 324) : (lace_y += 20) {
        canvas.rect(65, lace_y, 2, 4, colors.berry);
        canvas.rect(399, lace_y, 2, 4, colors.berry);
    }
    if (pixels) |image| paintGame(canvas, image) else canvas.centeredText(if (failed) "UNAVAILABLE" else "LOADING", 197, 2, colors.muted);
    if (failed and pixels != null) {
        canvas.rect(140, 191, 186, 26, colors.background);
        canvas.centeredText("STOPPED", 197, 2, colors.rose);
    }
    controls(canvas, keys);
    jirai.navigation(canvas, 3, navigation.demo_count, colors.rose, colors.border);
}

test "Doom touch pad supports diagonals and cancellation without stuck keys" {
    var controller: Controller = .{};
    try std.testing.expect(controller.input(.down, 140, 355));
    try std.testing.expectEqual(up | left, controller.keys);
    try std.testing.expect(controller.input(.move, 287, 370));
    try std.testing.expectEqual(@as(u16, 0), controller.keys);
    _ = controller.input(.move, 210, 405);
    try std.testing.expectEqual(down | right, controller.keys);
    _ = controller.input(.cancel, 0, 0);
    try std.testing.expectEqual(@as(u16, 0), controller.keys);
    _ = controller.input(.down, 287, 370);
    try std.testing.expectEqual(fire, controller.keys);
    _ = controller.input(.up, 287, 370);
    try std.testing.expectEqual(@as(u16, 0), controller.keys);
}
test "Doom overwritten key state always releases old keys before pressing new ones" {
    var keys: Keys = .{};
    try std.testing.expectEqual(Keys.Event{ .pressed = true, .code = 0xad }, keys.next(up | fire).?);
    try std.testing.expectEqual(Keys.Event{ .pressed = true, .code = 0xa3 }, keys.next(up | fire).?);
    try std.testing.expectEqual(Keys.Event{ .pressed = false, .code = 0xad }, keys.next(right).?);
    try std.testing.expectEqual(Keys.Event{ .pressed = false, .code = 0xa3 }, keys.next(right).?);
    try std.testing.expectEqual(Keys.Event{ .pressed = true, .code = 0xae }, keys.next(right).?);
    try std.testing.expectEqual(Keys.Event{ .pressed = false, .code = 0xae }, keys.next(0).?);
    try std.testing.expectEqual(@as(?Keys.Event, null), keys.next(0));
}
test "Doom clock freezes across repeated page-away commands and resumes without catch-up" {
    var clock: Clock = .{ .epoch_ms = 1000 };
    clock.setActive(false, 1200);
    clock.setActive(false, 1700);
    try std.testing.expectEqual(@as(u32, 201), clock.ticks(9000));
    clock.setActive(true, 9000);
    try std.testing.expectEqual(@as(u32, 251), clock.ticks(9050));
}
test "Doom aspect correction preserves every source pixel and stays inside the round panel" {
    const source = try std.testing.allocator.alloc(u16, pixel_count);
    defer std.testing.allocator.free(source);
    const frame = try std.testing.allocator.alloc(u16, 466 * 466);
    defer std.testing.allocator.free(frame);
    for (source, 0..) |*p, i| p.* = @truncate(i);
    @memset(frame, 0xDEAD);
    paintGame(pixel.Canvas.init(frame, 466, 466), source);
    for (0..240) |y| for (0..320) |x| {
        try std.testing.expectEqual(source[y * 200 / 240 * 320 + x], frame[(y + 90) * 466 + 73 + x]);
    };
    try std.testing.expectEqual(@as(u16, 0xDEAD), frame[90 * 466 + 72]);
    try std.testing.expectEqual(@as(u16, 0xDEAD), frame[330 * 466 + 73]);
    for ([_][2]i32{ .{ 73, 90 }, .{ 392, 90 }, .{ 73, 329 }, .{ 392, 329 } }) |p| {
        try std.testing.expect((p[0] - 233) * (p[0] - 233) + (p[1] - 233) * (p[1] - 233) < 233 * 233);
    }
}

test "every visible Doom button is fully inside the content touch circle" {
    const frame = try std.testing.allocator.alloc(u16, 466 * 466);
    defer std.testing.allocator.free(frame);
    @memset(frame, 0);
    controls(pixel.Canvas.init(frame, 466, 466), 0);
    const radius = 233 - navigation.edge_width;
    for (frame, 0..) |color, i| {
        if (color == 0) continue;
        const x: i32 = @intCast(i % 466);
        const y: i32 = @intCast(i / 466);
        try std.testing.expect((x - 233) * (x - 233) + (y - 233) * (y - 233) < radius * radius);
        var controller: Controller = .{};
        _ = controller.input(.down, x, y);
        try std.testing.expect(controller.keys != 0);
    }
}
