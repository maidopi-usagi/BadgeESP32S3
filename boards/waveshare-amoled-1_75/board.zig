pub const name = "Waveshare ESP32-S3-Touch-AMOLED-1.75";
pub const flash_bytes = 16 * 1024 * 1024;
pub const psram_bytes = 8 * 1024 * 1024;
pub const display = .{ .width = 466, .height = 466, .controller = "CO5300" };
pub const touch_controller = "CST9217";
pub const Display = @import("display.zig");
pub const Audio = @import("audio.zig");
pub const Imu = @import("imu.zig");
pub const Power = @import("power.zig");
pub const Battery = @import("battery.zig");
pub const pins = struct {
    pub const i2c = .{ .scl = 14, .sda = 15 };
    pub const lcd = .{ .data = [4]u8{ 4, 5, 6, 7 }, .clock = 38, .cs = 12, .reset = 39, .te = 13 };
    pub const touch = .{ .reset = 40, .interrupt = 11 };
    pub const usb = .{ .dm = 19, .dp = 20 };
    pub const audio = .{ .mclk = 42, .bclk = 9, .lrclk = 45, .out = 8, .input = 10, .amp = 46 };
};
