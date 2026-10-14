const I2c = @import("i2c.zig").Device;

pub const Direction = enum(u2) { standby, charging, discharging, reserved };
pub const ChargePhase = enum(u3) { trickle, precharge, constant_current, constant_voltage, done, idle, reserved6, reserved7 };
pub const Sample = struct {
    present: bool,
    vbus_good: bool,
    millivolts: ?u16,
    percent: ?u8,
    direction: Direction,
    phase: ChargePhase,
};

pub const Monitor = struct {
    device: I2c,

    pub fn open() !Monitor {
        const device = try I2c.open(0x34);
        errdefer device.close();
        var id: [1]u8 = undefined;
        try device.read(0x03, &id, 100);
        if (id[0] != 0x4A) return error.PmicIdentityMismatch;
        return .{ .device = device };
    }

    pub fn read(self: Monitor) !Sample {
        var status: [2]u8 = undefined;
        var control: [1]u8 = undefined;
        var adc: [1]u8 = undefined;
        var voltage: [2]u8 = undefined;
        var percent: [1]u8 = undefined;
        try self.device.read(0x00, &status, 100);
        try self.device.read(0x18, &control, 100);
        try self.device.read(0x30, &adc, 100);
        try self.device.read(0x34, &voltage, 100);
        try self.device.read(0xA4, &percent, 100);
        const present = status[0] & 0x08 != 0;
        const millivolts = (@as(u16, voltage[0] & 0x3F) << 8) | voltage[1];
        return .{
            .present = present,
            .vbus_good = status[0] & 0x20 != 0,
            .millivolts = if (present and adc[0] & 0x01 != 0 and millivolts != 0) millivolts else null,
            .percent = if (present and control[0] & 0x08 != 0 and percent[0] <= 100) percent[0] else null,
            .direction = @fromBackingInt(@intCast(@as(u2, @truncate(status[1] >> 5)))),
            .phase = @fromBackingInt(@intCast(@as(u3, @truncate(status[1])))),
        };
    }

    pub fn close(self: Monitor) void {
        self.device.close();
    }
};
