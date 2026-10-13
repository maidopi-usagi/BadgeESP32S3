const std = @import("std");

// Matches the narrow LVGL bridge ABI. Coordinates are physical panel pixels.
pub const Event = enum(u8) { down, move, up, cancel };
pub const drag_threshold = 12;
pub const tap_max_ms = 350;

pub const Tap = struct {
    press: ?struct { x: i32, y: i32, time_ms: u64, moved: bool = false } = null,

    pub fn pointer(self: *Tap, event: Event, x: i32, y: i32, now_ms: u64) bool {
        switch (event) {
            .down => self.press = .{ .x = x, .y = y, .time_ms = now_ms },
            .cancel => self.press = null,
            .move, .up => {
                if (self.press) |*press| {
                    const dx = x - press.x;
                    const dy = y - press.y;
                    press.moved = press.moved or dx * dx + dy * dy > drag_threshold * drag_threshold;
                    if (event == .up) {
                        const tapped = !press.moved and now_ms -| press.time_ms <= tap_max_ms;
                        self.press = null;
                        return tapped;
                    }
                }
            },
        }
        return false;
    }
};

test "tap requires a short release and never converts a returning drag or cancellation" {
    var tap: Tap = .{};
    try std.testing.expect(!tap.pointer(.up, 233, 233, 10));
    _ = tap.pointer(.down, 233, 233, 100);
    try std.testing.expect(tap.pointer(.up, 234, 234, 300));
    _ = tap.pointer(.down, 233, 233, 400);
    _ = tap.pointer(.move, 260, 233, 430);
    try std.testing.expect(!tap.pointer(.up, 233, 233, 500));
    _ = tap.pointer(.down, 233, 233, 600);
    try std.testing.expect(!tap.pointer(.up, 233, 233, 1000));
    _ = tap.pointer(.down, 233, 233, 1100);
    _ = tap.pointer(.cancel, 233, 233, 1110);
    try std.testing.expect(!tap.pointer(.up, 233, 233, 1120));
}
