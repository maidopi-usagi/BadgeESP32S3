#include "badge_bridge.h"
#include "bsp/esp-bsp.h"
#include "driver/usb_serial_jtag.h"
#include "esp_log.h"
#include "esp_pm.h"
#include "esp_sleep.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static esp_io_expander_handle_t power_io;

int badge_power_configure(void)
{
    /* RTOS locks restore 240MHz whenever either core has work. Keep APB at
     * 80MHz and retain the explicit, USB-aware PWR light-sleep policy. */
    const esp_pm_config_t config = {
        .max_freq_mhz = 240,
        .min_freq_mhz = 80,
        .light_sleep_enable = false,
    };
    esp_err_t err = esp_pm_configure(&config);
    if (err == ESP_OK) {
        ESP_LOGI("badge_power", "DFS ready: CPU 80-240MHz, APB 80MHz; automatic light-sleep disabled");
    }
    return err;
}

int badge_power_init(void)
{
    power_io = bsp_io_expander_init();
    if (!power_io) return ESP_FAIL;
    /* Preserve every other expander pin, including the codec's control lines. */
    return esp_io_expander_set_dir(power_io, IO_EXPANDER_PIN_NUM_4, IO_EXPANDER_INPUT);
}

int badge_power_read(void)
{
    uint32_t level = 0;
    if (!power_io || esp_io_expander_get_level(power_io, IO_EXPANDER_PIN_NUM_4, &level) != ESP_OK) return -1;
    return (level & IO_EXPANDER_PIN_NUM_4) != 0;
}

int badge_power_usb_connected(void) { return usb_serial_jtag_is_connected(); }

int badge_power_wait(int light_sleep)
{
    /* On this board PWR has no direct MCU wake GPIO. Poll the expander every
     * 20ms, keeping RAM and power rails intact. USB hosts require awake clocks. */
    if (!light_sleep || usb_serial_jtag_is_connected()) {
        vTaskDelay(pdMS_TO_TICKS(20));
        return ESP_OK;
    }
    esp_err_t err = esp_sleep_enable_timer_wakeup(20000);
    if (err == ESP_OK) err = esp_light_sleep_start();
    esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_TIMER);
    /* Let idle tasks feed watchdogs between manual light-sleep intervals. */
    vTaskDelay(1);
    return err;
}
