#include "badge_bridge.h"
#include "bsp/esp-bsp.h"
#include "bsp/display.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_lv_adapter.h"
#include "freertos/FreeRTOS.h"
#include <inttypes.h>
#include "lvgl.h"
#include "src/misc/cache/instance/lv_image_cache.h"

static bool ui_created;
static lv_image_dsc_t pixel_image;
static lv_image_dsc_t overlay_image;

static void refresh_stats(lv_event_t *event)
{
    static int64_t start_us;
    static uint32_t pixels, flushes, frames;
#if !BADGE_DISPLAY_BENCHMARK
    static int64_t window_start, total_us;
    static uint32_t window_frames, total_pixels;
#endif
    switch (lv_event_get_code(event)) {
    case LV_EVENT_REFR_START:
        start_us = esp_timer_get_time();
        pixels = flushes = 0;
        break;
    case LV_EVENT_FLUSH_START: {
        const lv_area_t *area = lv_event_get_param(event);
        pixels += lv_area_get_size(area);
        flushes++;
        break;
    }
    case LV_EVENT_REFR_READY:
        if (ui_created && flushes) {
            const int64_t now = esp_timer_get_time();
            const int64_t duration = now - start_us;
            const bool first = frames++ == 0;
            if (first) ESP_LOGI("badge_hw", "First pixel UI refresh completed: %" PRId64 " us, LVGL core=%d", duration, xPortGetCoreID());
            /* LVGL can return with the last DMA transfer still pending. */
#if BADGE_DISPLAY_BENCHMARK
            ESP_LOGI("badge_perf", "refresh #%" PRIu32 ": lvgl=%" PRId64 " us, pixels=%" PRIu32 ", flushes=%" PRIu32,
                     frames, duration, pixels, flushes);
#else
            if (first) {
                window_start = now;
                break;
            }
            window_frames++;
            total_us += duration;
            total_pixels += pixels;
            if (now - window_start >= 2000000) {
                const uint32_t fps_tenths = (uint64_t)window_frames * 10000000 / (now - window_start);
                ESP_LOGI("badge_perf", "LVGL updates=%" PRIu32 ", rate=%" PRIu32 ".%" PRIu32 "/s, avg refresh=%" PRId64 " us, pixels=%" PRIu32,
                         window_frames, fps_tenths / 10, fps_tenths % 10, total_us / window_frames, total_pixels / window_frames);
                window_start = now;
                window_frames = total_pixels = 0;
                total_us = 0;
            }
#endif
        }
        break;
    default:
        break;
    }
}

#if BADGE_DISPLAY_BENCHMARK
static void benchmark_refresh(lv_timer_t *timer)
{
    static uint32_t samples;
    if (samples++ == 12) {
        lv_timer_delete(timer);
        ESP_LOGI("badge_perf", "Display benchmark done: 12 redraws; no synthetic touch input");
        return;
    }
    lv_obj_invalidate(lv_timer_get_user_data(timer));
}
#endif

int badge_display_start(void)
{
    /* Keep rendering/flush work off core 0's persistent simulation tasks.
     * Explicitly preserve the BSP's default orientation, including touch. */
    bsp_display_cfg_t cfg = {
        .lv_adapter_cfg = ESP_LV_ADAPTER_DEFAULT_CONFIG(),
        .rotation = ESP_LV_ADAPTER_ROTATE_0,
        .tear_avoid_mode = ESP_LV_ADAPTER_TEAR_AVOID_MODE_NONE,
        .touch_flags = {.swap_xy = 0, .mirror_x = 1, .mirror_y = 1},
    };
    cfg.lv_adapter_cfg.task_core_id = 1;
    /* Both the 15ms refresh and 33ms animation periods are multiples of 3.
     * The adapter still owns stopping/restarting its tick on PWR suspend. */
    cfg.lv_adapter_cfg.tick_period_ms = 3;
    lv_display_t *display = bsp_display_start_with_config(&cfg);
    if (!display || !bsp_display_get_input_dev()) return ESP_FAIL;
    lv_display_add_event_cb(display, refresh_stats, LV_EVENT_REFR_START, NULL);
    lv_display_add_event_cb(display, refresh_stats, LV_EVENT_FLUSH_START, NULL);
    lv_display_add_event_cb(display, refresh_stats, LV_EVENT_REFR_READY, NULL);
    esp_err_t result = bsp_display_brightness_set(35);
    if (result == ESP_OK) {
        ESP_LOGI("badge_hw", "CO5300 display + CST9217 touch ready, brightness 35%%");
    }
    return result;
}

int badge_display_lock(uint32_t timeout_ms) { return bsp_display_lock(timeout_ms); }
void badge_display_unlock(void) { bsp_display_unlock(); }

void *badge_ui_pixels(uint16_t *pixels, uint16_t size, uint16_t scale, uint16_t offset)
{
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(0), 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
    lv_obj_remove_flag(screen, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(screen, LV_OBJ_FLAG_CLICKABLE);
    if (badge_touch_install() != ESP_OK) return NULL;

    pixel_image = (lv_image_dsc_t){
        .header = {
            .magic = LV_IMAGE_HEADER_MAGIC,
            .cf = LV_COLOR_FORMAT_RGB565,
            .w = size,
            .h = size,
            .stride = size * sizeof(uint16_t),
        },
        .data_size = size * size * sizeof(uint16_t),
        .data = (const uint8_t *)pixels,
    };
    lv_obj_t *image = lv_image_create(screen);
    if (!image) return NULL;
    lv_image_set_src(image, &pixel_image);
    lv_image_set_pivot(image, 0, 0);
    lv_image_set_scale(image, scale * LV_SCALE_NONE);
    lv_image_set_antialias(image, false);
    lv_obj_set_pos(image, offset, offset);
    lv_obj_remove_flag(image, LV_OBJ_FLAG_CLICKABLE);
    ui_created = true;
#if BADGE_DISPLAY_BENCHMARK
    lv_timer_create(benchmark_refresh, 500, image);
#endif
    return image;
}

void badge_ui_pixels_changed(void *image)
{
    /* Mutable RGB565 data can have a cached conversion; drop it before redraw. */
    lv_image_cache_drop(lv_image_get_src(image));
    lv_obj_invalidate(image);
}

void badge_ui_pixels_changed_area(void *image, uint16_t x, uint16_t y, uint16_t width, uint16_t height)
{
    const lv_area_t area = {.x1 = x, .y1 = y, .x2 = x + width - 1, .y2 = y + height - 1};
    lv_image_cache_drop(lv_image_get_src(image));
    lv_obj_invalidate_area(image, &area);
}

void *badge_ui_overlay(uint16_t *pixels, uint16_t width, uint16_t height, int16_t x, int16_t y)
{
    overlay_image = (lv_image_dsc_t){
        .header = {
            .magic = LV_IMAGE_HEADER_MAGIC,
            .cf = LV_COLOR_FORMAT_RGB565,
            .w = width,
            .h = height,
            .stride = width * sizeof(uint16_t),
        },
        .data_size = width * height * sizeof(uint16_t),
        .data = (const uint8_t *)pixels,
    };
    lv_obj_t *image = lv_image_create(lv_layer_top());
    if (!image) return NULL;
    lv_image_set_src(image, &overlay_image);
    lv_obj_set_pos(image, x, y);
    lv_obj_remove_flag(image, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    return image;
}

#if !BADGE_DISPLAY_BENCHMARK
static void animation_frame(lv_timer_t *timer)
{
    (void)timer;
    badge_on_frame((uint64_t)(esp_timer_get_time() / 1000));
}
#endif

int badge_ui_animate(uint32_t period_ms)
{
#if BADGE_DISPLAY_BENCHMARK
    (void)period_ms;
    ESP_LOGI("badge_perf", "Animation disabled for static display benchmark");
    return ESP_OK;
#else
    return lv_timer_create(animation_frame, period_ms, NULL) ? ESP_OK : ESP_ERR_NO_MEM;
#endif
}
