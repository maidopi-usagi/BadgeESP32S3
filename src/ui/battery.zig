const std = @import("std");
const pixel = @import("pixel_canvas.zig");
const colors = @import("theme.zig").colors;

pub const width = 84;
pub const height = 18;
pub const x = (pixel.Viewport.panel_size - width) / 2;
pub const y = 4;
pub const Mode = enum { unknown, absent, battery, usb, charging, full };
pub const Reading = struct {
    present: bool,
    percent: ?u8,
    external_power: bool,
    charging: bool,
    charge_done: bool,
};
pub const State = struct {
    percent: ?u8 = null,
    mode: Mode = .unknown,

    pub fn fromReading(reading: ?Reading) State {
        const value = reading orelse return .{};
        if (!value.present) return .{ .mode = .absent };
        return .{
            .percent = if (value.percent != null and value.percent.? <= 100) value.percent else null,
            .mode = if (!value.external_power) .battery else if (value.charging) .charging else if (value.charge_done) .full else .usb,
        };
    }

    pub fn pulse(self: State, now_ms: u64) bool {
        return self.mode == .charging and now_ms / 500 % 2 == 0;
    }
};

pub fn paint(canvas: pixel.Canvas, state: State, now_ms: u64) void {
    canvas.clear(colors.background);
    const low = state.mode == .battery and state.percent != null and state.percent.? <= 20;
    const ink = if (low) colors.rose else colors.accent;
    canvas.rect(2, 2, 24, 14, if (state.mode == .unknown or state.mode == .absent) colors.muted else ink);
    canvas.rect(4, 4, 20, 10, colors.background);
    canvas.rect(26, 6, 2, 6, colors.muted);
    if (state.percent) |percent| {
        const fill: i32 = @intCast((@as(u16, @min(percent, 100)) * 8 + 99) / 100);
        canvas.rect(6, 6, fill * 2, 6, ink);
    }
    switch (state.mode) {
        .charging => {
            canvas.rect(6, 4, 16, 10, colors.background);
            const bolt = if (state.pulse(now_ms)) colors.highlight else colors.rose;
            canvas.rect(14, 2, 4, 2, bolt);
            canvas.rect(12, 4, 4, 2, bolt);
            canvas.rect(10, 6, 10, 2, bolt);
            canvas.rect(14, 8, 4, 2, bolt);
            canvas.rect(12, 10, 4, 2, bolt);
            canvas.rect(10, 12, 4, 2, bolt);
        },
        .full => {
            canvas.rect(8, 8, 2, 2, colors.background);
            canvas.rect(10, 10, 2, 2, colors.background);
            canvas.rect(12, 8, 2, 2, colors.background);
            canvas.rect(14, 6, 2, 2, colors.background);
        },
        .usb => {
            canvas.rect(8, 4, 12, 10, colors.background);
            canvas.rect(10, 4, 2, 2, colors.highlight);
            canvas.rect(16, 4, 2, 2, colors.highlight);
            canvas.rect(10, 6, 8, 4, colors.highlight);
            canvas.rect(12, 10, 4, 4, colors.highlight);
        },
        .absent => {
            canvas.rect(8, 6, 12, 2, colors.muted);
            canvas.rect(12, 4, 4, 6, colors.muted);
        },
        else => {},
    }
    var text: [4]u8 = undefined;
    const label = if (state.percent) |percent| std.fmt.bufPrint(&text, "{d}%", .{@min(percent, 100)}) catch "--%" else "--%";
    canvas.text(label, width - 4 - @as(i32, @intCast(label.len * 12 - 2)), 2, 2, if (low) colors.rose else colors.text);
}

pub fn composite(canvas: pixel.Canvas, state: State, now_ms: u64) void {
    var pixels: [width * height]u16 = undefined;
    paint(pixel.Canvas.init(&pixels, width, height), state, now_ms);
    for (0..height) |row| {
        for (0..width) |column| canvas.pixel(x + @as(i32, @intCast(column)), y + @as(i32, @intCast(row)), pixels[row * width + column]);
    }
}

test "battery status separates external power, charging and unavailable readings" {
    const reading: Reading = .{ .present = true, .percent = 74, .external_power = true, .charging = false, .charge_done = false };
    try std.testing.expectEqual(Mode.usb, State.fromReading(reading).mode);
    var changed = reading;
    changed.charging = true;
    try std.testing.expectEqual(Mode.charging, State.fromReading(changed).mode);
    changed.external_power = false;
    changed.charge_done = true;
    try std.testing.expectEqual(Mode.battery, State.fromReading(changed).mode);
    changed = reading;
    changed.charge_done = true;
    try std.testing.expectEqual(Mode.full, State.fromReading(changed).mode);
    changed.present = false;
    const absent = State.fromReading(changed);
    try std.testing.expectEqual(Mode.absent, absent.mode);
    try std.testing.expectEqual(null, absent.percent);
    try std.testing.expectEqual(State{}, State.fromReading(null));
    changed = reading;
    changed.percent = 255;
    try std.testing.expectEqual(null, State.fromReading(changed).percent);
}
