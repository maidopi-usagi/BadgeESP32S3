#include "badge_bridge.h"
#include "bsp/esp-bsp.h"
#include "esp_lcd_touch.h"
#include "esp_lcd_panel_io.h"
#include "esp_lv_adapter_input.h"
#include "esp_timer.h"
#include "esp_log.h"
_Static_assert(sizeof(badge_touch_point_t) == 6, "Zig touch point ABI mismatch");

static esp_err_t read_frame(esp_lcd_touch_handle_t tp, esp_lcd_touch_point_data_t *out,
                            uint8_t *count, uint8_t capacity, void *ctx)
{
    (void)ctx;
    uint8_t data[30] = {0};
    const uint8_t address = 0x00;
    esp_err_t ret = esp_lcd_panel_io_tx_param(tp->io, 0xD0, &address, 1);
    if (ret == ESP_OK) ret = esp_lcd_panel_io_rx_param(tp->io, -1, data, sizeof(data));
    /* Consume the report even if decoding fails. No reset/firmware writes. */
    const uint8_t ack[2] = {0x00, 0xAB};
    if (ret == ESP_OK) ret = esp_lcd_panel_io_tx_param(tp->io, 0xD0, ack, sizeof(ack));
    badge_touch_point_t points[5] = {0};
    /* custom_touch_read bypasses esp_lcd_touch_get_data's software orientation.
     * Carry the BSP flags into Zig once, for every contact and every demo. */
    const uint8_t orientation =
        ((tp->config.flags.mirror_x && tp->set_mirror_x == NULL) ? BADGE_TOUCH_MIRROR_X : 0) |
        ((tp->config.flags.mirror_y && tp->set_mirror_y == NULL) ? BADGE_TOUCH_MIRROR_Y : 0) |
        ((tp->config.flags.swap_xy && tp->set_swap_xy == NULL) ? BADGE_TOUCH_SWAP_XY : 0);
    int n = ret == ESP_OK ? badge_decode_touch(data, sizeof(data), points, orientation) : -1;
    const uint64_t now = esp_timer_get_time() / 1000;
    badge_on_touches(points, n < 0 ? UINT8_MAX : n, now);
    *count = 0;
    if (n > 0 && capacity > 0) {
        out[0] = (esp_lcd_touch_point_data_t){.track_id = points[0].id, .x = points[0].x,
                                           .y = points[0].y, .strength = 1};
        *count = 1;
    }
    return ret;
}

int badge_touch_install(void)
{
    const esp_lv_adapter_touch_callbacks_t callbacks = {.custom_touch_read = read_frame};
    const esp_err_t result = esp_lv_adapter_set_touch_callbacks(bsp_display_get_input_dev(), &callbacks);
    if (result == ESP_OK) ESP_LOGI("badge_touch", "CST9217 full report: up to 5 contacts; actual panel capacity requires measurement");
    return result;
}

void badge_touch_resync(void)
{
    /* Re-read even if release happened while LVGL was paused. Without this,
     * IRQ-only input could leave the wake guard armed until the next tap. */
    esp_lv_adapter_touch_notify_interrupt(bsp_display_get_input_dev());
}
