const std = @import("std");

pub fn Clock(comptime hz: u32, comptime max_steps: u8) type {
    return struct {
        const Self = @This();
        last_us: ?u64 = null,
        remainder: u64 = 0,
        dropped_us: u64 = 0,

        pub fn clear(self: *Self) void {
            self.last_us = null;
            self.remainder = 0;
        }

        pub fn advance(self: *Self, now: u64) u8 {
            const elapsed = if (self.last_us) |last| now -| last else 0;
            self.last_us = now;
            const accepted = @as(u64, @min(elapsed, 50_000));
            self.remainder += accepted * hz;
            self.dropped_us += elapsed - accepted;
            const requested = self.remainder / 1_000_000;
            const count = @min(requested, max_steps);
            self.remainder %= 1_000_000;
            self.dropped_us += (requested - count) * 1_000_000 / hz;
            return @intCast(count);
        }

        pub fn waitMs(self: *const Self, now: u64, next_event: ?u64) u32 {
            const last = self.last_us orelse return 1;
            const until_step = (1_000_000 - self.remainder + hz - 1) / hz;
            var remaining = until_step -| (now -| last);
            if (next_event) |deadline| remaining = @min(remaining, deadline -| now);
            return @intCast(@max(1, (remaining + 999) / 1000));
        }
    };
}

test "deadline waits retain 120 and 240Hz with compute time and early input wakes" {
    inline for (.{ 120, 240 }) |hz| {
        var clock: Clock(hz, 8) = .{};
        var now: u64 = 0;
        var steps: u64 = 0;
        var wakes: u32 = 0;
        _ = clock.advance(now);
        while (now < 10_000_000) {
            const work: u64 = if (wakes % 3 == 0) 2100 else 230;
            now += work;
            const wait_us = @as(u64, clock.waitMs(now, null)) * 1000;
            now += if (wakes % 7 == 0) @min(wait_us, 400) else wait_us;
            steps += clock.advance(now);
            wakes += 1;
            try std.testing.expectEqual(now * hz / 1_000_000, steps);
        }
        try std.testing.expectEqual(@as(u64, 0), clock.dropped_us);
        try std.testing.expect(wakes < hz * 15);
    }
}

test "deadline after fractional steps, overrun and resume never busy spins or catches up paused time" {
    var clock: Clock(120, 2) = .{};
    _ = clock.advance(0);
    try std.testing.expectEqual(@as(u32, 9), clock.waitMs(0, null));
    try std.testing.expectEqual(@as(u32, 3), clock.waitMs(6000, null));
    try std.testing.expectEqual(@as(u32, 1), clock.waitMs(20_000, null));
    try std.testing.expectEqual(@as(u8, 1), clock.advance(9000));
    try std.testing.expectEqual(@as(u32, 8), clock.waitMs(9000, null));
    try std.testing.expectEqual(@as(u8, 2), clock.advance(1_000_000));
    try std.testing.expect(clock.dropped_us > 900_000);
    clock.clear();
    try std.testing.expectEqual(@as(u32, 1), clock.waitMs(60_000_000, null));
    try std.testing.expectEqual(@as(u8, 0), clock.advance(60_000_000));
    try std.testing.expectEqual(@as(u32, 9), clock.waitMs(60_000_000, null));
}

test "snapshot deadlines are not rounded to the next simulation step" {
    var clock: Clock(120, 2) = .{};
    _ = clock.advance(0);
    try std.testing.expectEqual(@as(u32, 2), clock.waitMs(0, 1800));
    try std.testing.expectEqual(@as(u32, 1), clock.waitMs(2000, 1800));
    var now: u64 = 0;
    var last_frame: u64 = 0;
    var frames: u32 = 0;
    while (now < 10_000_000) {
        now += 230;
        now += @as(u64, clock.waitMs(now, last_frame + 33_333)) * 1000;
        _ = clock.advance(now);
        if (now - last_frame >= 33_333) {
            try std.testing.expect(now - last_frame <= 34_333);
            last_frame = now;
            frames += 1;
        }
    }
    try std.testing.expect(frames >= 290 and frames <= 300);
}
