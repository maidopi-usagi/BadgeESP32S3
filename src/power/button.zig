const std = @import("std");
pub const debounce_ms = 30;
pub const Button = struct {
    candidate: ?bool = null,
    since: u64 = 0,
    armed: bool = false,

    pub fn sample(self: *Button, pressed: ?bool, now: u64) bool {
        const value = pressed orelse {
            self.candidate = null;
            return false;
        };
        if (self.candidate == null or self.candidate.? != value or now < self.since) {
            self.candidate = value;
            self.since = now;
            return false;
        }
        if (now - self.since < debounce_ms) return false;
        if (!value) {
            self.armed = true;
            return false;
        }
        if (!self.armed) return false;
        self.armed = false;
        return true;
    }
};

test "PWR debounce ignores boot hold and bounce, then fires once per press" {
    var button: Button = .{};
    try std.testing.expect(!button.sample(true, 0));
    try std.testing.expect(!button.sample(true, 2000));
    try std.testing.expect(!button.sample(false, 2020));
    try std.testing.expect(!button.sample(false, 2060));
    try std.testing.expect(!button.sample(true, 2080));
    try std.testing.expect(!button.sample(false, 2090));
    try std.testing.expect(!button.sample(true, 2100));
    try std.testing.expect(!button.sample(true, 2120));
    try std.testing.expect(button.sample(true, 2140));
    try std.testing.expect(!button.sample(true, 5000));
    try std.testing.expect(!button.sample(false, 5020));
    try std.testing.expect(!button.sample(false, 5060));
    try std.testing.expect(!button.sample(true, 5080));
    try std.testing.expect(button.sample(true, 5120));
}

test "PWR read failures cannot release a held key or count across missing samples" {
    var button: Button = .{};
    _ = button.sample(false, 0);
    _ = button.sample(false, 40);
    _ = button.sample(true, 60);
    try std.testing.expect(!button.sample(null, 80));
    try std.testing.expect(!button.sample(true, 100));
    try std.testing.expect(button.sample(true, 140));
    _ = button.sample(null, 160);
    _ = button.sample(true, 180);
    try std.testing.expect(!button.sample(true, 300));
}
