const log = @import("std").log.scoped(.espressif);
const Handle = *anyopaque;

// IDF 5.5.2 i2c_device_config_t; translate-c leaves its bitfield opaque.
const DeviceConfig = extern struct {
    address_length: c_int = 0,
    address: u16,
    speed_hz: u32 = 400000,
    wait_us: u32 = 0,
    flags: u32 = 0,
};
comptime {
    if (@sizeOf(DeviceConfig) != 20 or @offsetOf(DeviceConfig, "speed_hz") != 8 or @offsetOf(DeviceConfig, "flags") != 16) @compileError("I2C device-config ABI mismatch");
}
extern fn bsp_i2c_get_handle() ?Handle;
extern fn i2c_master_bus_add_device(bus: Handle, config: *const DeviceConfig, device: *?Handle) c_int;
extern fn i2c_master_bus_rm_device(device: Handle) c_int;
extern fn i2c_master_transmit(device: Handle, data: [*]const u8, size: usize, timeout_ms: c_int) c_int;
extern fn i2c_master_transmit_receive(device: Handle, data: [*]const u8, size: usize, output: [*]u8, output_size: usize, timeout_ms: c_int) c_int;

pub const Device = struct {
    handle: Handle,
    address: u7,

    pub fn open(address: u7) !Device {
        const bus = bsp_i2c_get_handle() orelse return error.I2cNotReady;
        const config: DeviceConfig = .{ .address = address };
        var handle: ?Handle = null;
        if (i2c_master_bus_add_device(bus, &config, &handle) != 0) return error.I2cAddFailed;
        return .{ .handle = handle.?, .address = address };
    }

    pub fn read(self: Device, reg: u8, output: []u8, timeout_ms: c_int) !void {
        const address = [_]u8{reg};
        const result = i2c_master_transmit_receive(self.handle, &address, 1, output.ptr, output.len, timeout_ms);
        if (result != 0) {
            log.warn("I2C read addr=0x{x}, reg=0x{x}, IDF error=0x{x}", .{ self.address, reg, result });
            return error.I2cReadFailed;
        }
    }

    pub fn write(self: Device, reg: u8, value: u8, timeout_ms: c_int) !void {
        const bytes = [_]u8{ reg, value };
        const result = i2c_master_transmit(self.handle, &bytes, bytes.len, timeout_ms);
        if (result != 0) {
            log.warn("I2C write addr=0x{x}, reg=0x{x}, IDF error=0x{x}", .{ self.address, reg, result });
            return error.I2cWriteFailed;
        }
    }

    pub fn close(self: Device) void {
        _ = i2c_master_bus_rm_device(self.handle);
    }
};
