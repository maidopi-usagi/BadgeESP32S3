#pragma once
#include <stdint.h>

int badge_display_start(void);
int badge_display_lock(uint32_t timeout_ms);
void badge_display_unlock(void);
void *badge_ui_pixels(uint16_t *pixels, uint16_t size, uint16_t scale, uint16_t offset);
void badge_ui_pixels_changed(void *image);
void badge_ui_pixels_changed_area(void *image, uint16_t x, uint16_t y, uint16_t width, uint16_t height);
void *badge_ui_overlay(uint16_t *pixels, uint16_t width, uint16_t height, int16_t x, int16_t y);
int badge_ui_animate(uint32_t period_ms);
int badge_touch_install(void);
void badge_touch_resync(void);
int badge_display_sleep(int sleeping);
int badge_power_configure(void);
int badge_power_init(void);
int badge_power_read(void);
int badge_power_usb_connected(void);
int badge_power_wait(int light_sleep);
int badge_audio_prepare(void);
typedef struct { uint16_t x, y; uint8_t id; } badge_touch_point_t;
enum badge_touch_orientation { BADGE_TOUCH_MIRROR_X = 1, BADGE_TOUCH_MIRROR_Y = 2, BADGE_TOUCH_SWAP_XY = 4 };
int badge_decode_touch(const uint8_t *data, uint32_t length, badge_touch_point_t *points, uint8_t orientation);
void badge_on_touches(const badge_touch_point_t *points, uint8_t count, uint64_t now_ms);

/* Implemented by Zig; LVGL calls these while holding the display mutex. */
enum badge_pointer_event { BADGE_POINTER_DOWN, BADGE_POINTER_MOVE, BADGE_POINTER_UP, BADGE_POINTER_CANCEL };
void badge_on_pointer(uint8_t event, int32_t x, int32_t y, uint64_t now_ms);
void badge_on_frame(uint64_t now_ms);
