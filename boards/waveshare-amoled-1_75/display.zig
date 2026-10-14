pub const Object = *anyopaque;

extern fn badge_display_start() c_int;
extern fn badge_display_lock(timeout_ms: u32) c_int;
extern fn badge_display_unlock() void;
pub extern fn badge_ui_pixels(pixels: [*]u16, size: u16, scale: u16, offset: u16) ?Object;
pub extern fn badge_ui_pixels_changed(image: Object) void;
pub extern fn badge_ui_pixels_changed_area(image: Object, x: u16, y: u16, width: u16, height: u16) void;
pub extern fn badge_ui_overlay(pixels: [*]u16, width: u16, height: u16, x: i16, y: i16) ?Object;
extern fn badge_ui_animate(period_ms: u32) c_int;
extern fn esp_lv_adapter_pause(timeout_ms: i32) c_int;
extern fn esp_lv_adapter_resume() c_int;
extern fn badge_display_sleep(sleeping: c_int) c_int;
pub extern fn badge_touch_resync() void;

pub fn pause() !void {
    if (esp_lv_adapter_pause(2000) != 0) return error.DisplayPauseFailed;
}
pub fn resumeAfterSleep() !void {
    if (esp_lv_adapter_resume() != 0) return error.DisplayResumeFailed;
}
pub fn sleep(sleeping: bool) !void {
    if (badge_display_sleep(@intFromBool(sleeping)) != 0) return error.PanelSleepFailed;
}

pub fn animate(period_ms: u32) !void {
    if (badge_ui_animate(period_ms) != 0) return error.AnimationTimerCreateFailed;
}

pub fn start() !void {
    if (badge_display_start() != 0) return error.DisplayStartFailed;
}
pub fn lock() !void {
    if (badge_display_lock(5000) != 0) return error.DisplayLockFailed;
}
pub fn unlock() void {
    badge_display_unlock();
}
