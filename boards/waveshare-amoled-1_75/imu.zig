const std = @import("std");
const log = std.log.scoped(.espressif);
const Handle = *anyopaque;
// IDF 5.5.2 i2c_device_config_t; translate-c leaves its bitfield opaque.
const DeviceConfig = extern struct {
    address_length: c_int = 0, // I2C_ADDR_BIT_LEN_7
    address: u16 = 0x6B,
    speed_hz: u32 = 400000,
    wait_us: u32 = 0,
    flags: u32 = 0, // ACK checking enabled
};
comptime {
    if (@sizeOf(DeviceConfig) != 20 or @offsetOf(DeviceConfig, "speed_hz") != 8 or @offsetOf(DeviceConfig, "flags") != 16) @compileError("I2C device-config ABI mismatch");
}
extern fn bsp_i2c_get_handle() ?Handle;
extern fn i2c_master_bus_add_device(bus: Handle, config: *const DeviceConfig, device: *?Handle) c_int;
extern fn i2c_master_bus_rm_device(device: Handle) c_int;
extern fn i2c_master_transmit(device: Handle, data: [*]const u8, size: usize, timeout_ms: c_int) c_int;
extern fn i2c_master_transmit_receive(device: Handle, data: [*]const u8, size: usize, output: [*]u8, output_size: usize, timeout_ms: c_int) c_int;

var device: ?Handle = null;
pub const Mode = enum { off, accelerometer, six_axis };
var mode: Mode = .off; // Owned by the motion worker, together with the I2C device.
pub const Info = struct { id: u8, revision: u8 };
pub const Sample = struct { accel: [3]i16, gyro: [3]i16 };
pub const accel_lsb_per_g: f32 = 8192;
pub const gyro_lsb_per_dps: f32 = 128;

// Screen frame (right, up, towards viewer) at the BSP's rotation 0.
pub fn screenAxes(values: [3]f32) [3]f32 {
    return .{ values[1], values[0], -values[2] };
}

pub fn open(delay_ms: *const fn (u32) void) !Info {
    const bus = bsp_i2c_get_handle() orelse return error.I2cNotReady;
    const config: DeviceConfig = .{};
    if (i2c_master_bus_add_device(bus, &config, &device) != 0) return error.ImuAddFailed;
    errdefer close();
    var id: [1]u8 = undefined;
    try read(0x00, &id);
    if (id[0] != 0x05) return error.ImuIdentityMismatch;
    try write(0x60, 0xB0);
    var reset_done = false;
    for (0..10) |_| {
        delay_ms(10);
        var result: [1]u8 = undefined;
        try read(0x4D, &result);
        if (result[0] == 0x80) {
            reset_done = true;
            break;
        }
    }
    if (!reset_done) return error.ImuResetTimeout;
    try write(0x02, 0x40); // Auto-increment, little-endian, interrupt outputs off.
    try write(0x08, 0x00); // Configure while both sensors are disabled.
    try write(0x03, 0x16); // Accelerometer +/-4 g, 112.1 Hz in 6-DoF mode.
    try write(0x04, 0x46); // Gyroscope +/-256 dps, 112.1 Hz.
    try write(0x06, 0x55); // Both LPFs enabled, mode 2 (~6 Hz bandwidth).
    try setMode(.off);
    for ([_][2]u8{ .{ 0x02, 0x40 }, .{ 0x03, 0x1C }, .{ 0x04, 0x46 }, .{ 0x06, 0x55 }, .{ 0x08, 0x00 } }) |setting| {
        var value: [1]u8 = undefined;
        try read(setting[0], &value);
        if (value[0] != setting[1]) return error.ImuSettingMismatch;
    }
    var identity: [2]u8 = undefined;
    try read(0x00, &identity);
    return .{ .id = identity[0], .revision = identity[1] };
}

pub fn sample() !?Sample {
    if (mode == .off) return null;
    var status: [1]u8 = undefined;
    try readWithTimeout(0x2E, &status, 20);
    const ready_mask: u8 = if (mode == .six_axis) 0x03 else 0x01;
    if (status[0] & ready_mask != ready_mask) return null;
    var bytes: [12]u8 = @splat(0);
    // With gyro disabled only acceleration is fresh; never consume stale gDA.
    try readWithTimeout(0x35, bytes[0..@as(usize, if (mode == .six_axis) 12 else 6)], 20);
    var result: Sample = undefined;
    for (0..3) |i| {
        result.accel[i] = std.mem.readInt(i16, bytes[i * 2 ..][0..2], .little);
        result.gyro[i] = std.mem.readInt(i16, bytes[6 + i * 2 ..][0..2], .little);
    }
    return result;
}

pub fn setMode(next: Mode) !void {
    try write(0x08, 0x00);
    // aODR=1100 with both sensors off selects low-power idle, without the
    // slow full power-down/reset path. Active +/-4g mode remains 0x16:
    // ~125Hz with accel alone, ~112Hz synchronized to the gyro in six-axis.
    const accel_config: u8 = if (next == .off) 0x1C else 0x16;
    const enable: u8 = switch (next) {
        .off => 0x00,
        .accelerometer => 0x21,
        .six_axis => 0x23,
    };
    try write(0x03, accel_config);
    try write(0x08, enable);
    for ([_][2]u8{ .{ 0x03, accel_config }, .{ 0x08, enable } }) |setting| {
        var value: [1]u8 = undefined;
        try read(setting[0], &value);
        if (value[0] != setting[1]) return error.ImuModeMismatch;
    }
    mode = next;
}

fn read(reg: u8, output: []u8) !void {
    // Codec startup has higher task priority and shares this I2C bus. Its
    // register burst can exceed 20ms; configuration may wait, samples may not.
    return readWithTimeout(reg, output, 100);
}

fn readWithTimeout(reg: u8, output: []u8, timeout_ms: c_int) !void {
    const handle = device orelse return error.ImuNotOpen;
    const address = [_]u8{reg};
    const result = i2c_master_transmit_receive(handle, &address, 1, output.ptr, output.len, timeout_ms);
    if (result != 0) {
        log.warn("IMU read reg=0x{x}, IDF error=0x{x}", .{ reg, result });
        return error.ImuReadFailed;
    }
}

fn write(reg: u8, value: u8) !void {
    const handle = device orelse return error.ImuNotOpen;
    const bytes = [_]u8{ reg, value };
    const result = i2c_master_transmit(handle, &bytes, bytes.len, 100);
    if (result != 0) {
        log.warn("IMU write reg=0x{x}, IDF error=0x{x}", .{ reg, result });
        return error.ImuWriteFailed;
    }
}

pub fn close() void {
    if (device) |handle| {
        setMode(.off) catch {};
        _ = i2c_master_bus_rm_device(handle);
        device = null;
    }
    mode = .off;
}
