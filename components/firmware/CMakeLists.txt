idf_component_register(
    SRCS "badge_bridge.c" "badge_touch.c" "badge_display_policy.c" "badge_power.c" "badge_audio_policy.c"
    INCLUDE_DIRS "include"
    REQUIRES freertos heap log esp_system esp_timer esp_psram esp_driver_usb_serial_jtag esp_hw_support esp_pm
        waveshare__esp32_s3_touch_amoled_1_75 lvgl__lvgl espressif__esp_codec_dev doom_engine
        espressif__esp_lvgl_adapter espressif__esp_lcd_touch esp_lcd
)
option(BADGE_DISPLAY_BENCHMARK "Run 12 automatic display redraws at boot" OFF)
target_compile_definitions(${COMPONENT_LIB} PRIVATE BADGE_DISPLAY_BENCHMARK=$<BOOL:${BADGE_DISPLAY_BENCHMARK}>)
# The pinned BSP does not expose draw-buffer placement/height in its public cfg.
target_link_options(${COMPONENT_LIB} INTERFACE
    "-Wl,--wrap=esp_lv_adapter_register_display"
    "-Wl,--undefined=__wrap_esp_lv_adapter_register_display"
    "-Wl,--wrap=audio_codec_new_i2s_data"
    "-Wl,--undefined=__wrap_audio_codec_new_i2s_data"
)
include(${CMAKE_SOURCE_DIR}/third_party/zig-esp-idf/cmake/zig-config.cmake)
