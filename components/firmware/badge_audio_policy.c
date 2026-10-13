#include "badge_bridge.h"
#include "bsp/esp-bsp.h"
#include "esp_codec_dev_defaults.h"
#include "esp_log.h"

/* BSP 3.0.1 starts both I2S channels even for its speaker-only constructor.
 * Retain BSP/codec ownership, and use the public data interface to disable RX
 * before opening the output codec. No microphone is used by this application. */
static const audio_codec_data_if_t *speaker_data;
static bool rx_disabled;

extern const audio_codec_data_if_t *__real_audio_codec_new_i2s_data(const audio_codec_i2s_cfg_t *config);

const audio_codec_data_if_t *__wrap_audio_codec_new_i2s_data(const audio_codec_i2s_cfg_t *config)
{
    const audio_codec_data_if_t *data = __real_audio_codec_new_i2s_data(config);
    if (data && config->port == CONFIG_BSP_I2S_NUM && config->tx_handle && config->rx_handle) {
        speaker_data = data;
        rx_disabled = false;
    }
    return data;
}

int badge_audio_prepare(void)
{
    if (!speaker_data || !speaker_data->enable) return ESP_ERR_INVALID_STATE;
    if (rx_disabled) return ESP_OK;
    int err = speaker_data->enable(speaker_data, ESP_CODEC_DEV_TYPE_IN, false);
    if (err != ESP_CODEC_DEV_OK) return ESP_FAIL;
    rx_disabled = true;
    ESP_LOGI("badge_audio", "Unused I2S RX disabled; codec retains playback TX ownership");
    return ESP_OK;
}
