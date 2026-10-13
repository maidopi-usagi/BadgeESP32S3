#include "badge_bridge.h"
#include "bsp/esp-bsp.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_io.h"
#include "esp_log.h"
#include "esp_lv_adapter.h"
#include "esp_memory_utils.h"
#include "lvgl.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

enum { DRAW_ROWS = 16 };
static esp_lcd_panel_handle_t retained_panel;
static esp_lcd_panel_io_handle_t retained_io;

extern lv_display_t *__real_esp_lv_adapter_register_display(const esp_lv_adapter_display_config_t *config);

static esp_err_t draw_dma(lv_display_t *display, esp_lcd_panel_handle_t panel,
                          int x1, int y1, int x2, int y2, const void *pixels, void *user)
{
    (void)display;
    (void)user;
    if (!esp_ptr_dma_capable(pixels)) {
        ESP_LOGE("badge_dma", "Display buffer is not DMA-capable");
        return ESP_ERR_INVALID_STATE;
    }
    return esp_lcd_panel_draw_bitmap(panel, x1, y1, x2, y2, pixels);
}

lv_display_t *__wrap_esp_lv_adapter_register_display(const esp_lv_adapter_display_config_t *config)
{
    if (!config) return NULL;
    esp_lv_adapter_display_config_t local = *config;
    /* The BSP hardcodes two 50-row PSRAM buffers. On S3 each transfer then
     * requests up to 46600 contiguous internal bytes. Persistent demo tasks can
     * exhaust that block; failed transfers leave pixels from earlier pages.
     * Reserve two smaller DMA-capable buffers once, before any demo is opened. */
    local.profile.buffer_height = DRAW_ROWS;
    local.profile.use_psram = false;
    local.profile.require_double_buffer = true;
    lv_display_t *display = __real_esp_lv_adapter_register_display(&local);
    if (!display) return NULL;
    const esp_lv_adapter_draw_bitmap_callbacks_t callbacks = {.custom_draw_bitmap = draw_dma};
    if (esp_lv_adapter_set_draw_bitmap_callbacks(display, &callbacks, NULL) != ESP_OK) {
        esp_lv_adapter_unregister_display(display);
        return NULL;
    }
    retained_panel = local.panel;
    retained_io = local.panel_io;
    ESP_LOGI("badge_dma", "Fixed internal DMA buffers: 2 x %u bytes; free=%u, largest=%u",
             (unsigned)(BSP_LCD_H_RES * DRAW_ROWS * sizeof(uint16_t)),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DMA));
    return display;
}

/* Only called with the adapter paused and all application workers quiescent.
 * SPI tx_param drains pending DMA before sending panel sleep commands. */
int badge_display_sleep(int sleeping)
{
    if (!retained_panel || !retained_io) return ESP_ERR_INVALID_STATE;
    esp_err_t err;
    if (sleeping) {
        err = esp_lcd_panel_disp_on_off(retained_panel, false);
        if (err != ESP_OK) return err;
        err = esp_lcd_panel_io_tx_param(retained_io, 0x02001000, NULL, 0); // CO5300 SLPIN
    } else {
        err = esp_lcd_panel_io_tx_param(retained_io, 0x02001100, NULL, 0); // SLPOUT
    }
    if (err != ESP_OK) return err;
    vTaskDelay(pdMS_TO_TICKS(120));
    return sleeping ? ESP_OK : esp_lcd_panel_disp_on_off(retained_panel, true);
}
