//! PWR is TCA9554 P4/SYS_OUT, active high; never cut AXP2101 power rails.
extern fn badge_power_configure() c_int;
extern fn badge_power_init() c_int;
extern fn badge_power_read() c_int;
extern fn badge_power_usb_connected() c_int;
extern fn badge_power_wait(light_sleep: c_int) c_int;
pub fn configure() !void {
    if (badge_power_configure() != 0) return error.DynamicFrequencyScalingFailed;
}
pub fn init() !void {
    if (badge_power_init() != 0) return error.PowerKeyInitFailed;
}
pub fn pressed() !bool {
    const value = badge_power_read();
    if (value < 0) return error.PowerKeyReadFailed;
    return value != 0;
}
pub fn usbConnected() bool {
    return badge_power_usb_connected() != 0;
}
pub fn wait(light_sleep: bool) !void {
    if (badge_power_wait(@intFromBool(light_sleep)) != 0) return error.LightSleepFailed;
}
