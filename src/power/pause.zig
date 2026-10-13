const std = @import("std");
pub const Latch = struct {
    ticket: u32 = 0, // UI-owned; read by the power task only with LVGL paused.
    acknowledged: std.atomic.Value(u32) = .init(0),
    stopped: std.atomic.Value(bool) = .init(false),

    pub fn request(self: *Latch) void {
        self.ticket +%= 1;
    }
    pub fn ack(self: *Latch, ticket: u32) void {
        self.acknowledged.store(ticket, .release);
    }
    pub fn quiet(self: *const Latch) bool {
        return self.stopped.load(.acquire) or self.acknowledged.load(.acquire) == self.ticket;
    }
    pub fn stop(self: *Latch) void {
        // Only after all peripheral cleanup is finished.
        self.stopped.store(true, .release);
    }
};

test "sleep waits for the current pause command, not an older idle acknowledgment" {
    var latch: Latch = .{};
    try std.testing.expect(latch.quiet());
    latch.request();
    const old = latch.ticket;
    latch.request();
    latch.ack(old);
    try std.testing.expect(!latch.quiet());
    latch.ack(latch.ticket);
    try std.testing.expect(latch.quiet());
    latch.request();
    try std.testing.expect(!latch.quiet());
    latch.stop();
    try std.testing.expect(latch.quiet());
}
