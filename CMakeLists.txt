cmake_minimum_required(VERSION 3.22)

set(IDF_TARGET "esp32s3" CACHE STRING "Firmware target")
if(NOT IDF_TARGET STREQUAL "esp32s3")
    message(FATAL_ERROR "This project targets Waveshare ESP32-S3-Touch-AMOLED-1.75")
endif()
set(SDKCONFIG "${CMAKE_BINARY_DIR}/sdkconfig")
set(SDKCONFIG_DEFAULTS "${CMAKE_SOURCE_DIR}/boards/waveshare-amoled-1_75/sdkconfig.defaults")
set(ZIG_BUILD_TYPE "ReleaseSafe" CACHE STRING "Zig optimization mode")
set(ZIG_PIXEL_SCALE "4" CACHE STRING "Integer pixel canvas scale: 2 or 4")
set(ZIG_START_DEMO "fumo" CACHE STRING "Boot demo: fumo, dice, cornell, doom, sandbox, rhythm, fluid or physics")
option(ZIG_RHYTHM_AUTOPLAY "Automatically play one Orbit track for hardware measurement" OFF)
if(ZIG_RHYTHM_AUTOPLAY)
    set(ZIG_RHYTHM_AUTOPLAY_VALUE true)
else()
    set(ZIG_RHYTHM_AUTOPLAY_VALUE false)
endif()
if(NOT ZIG_START_DEMO MATCHES "^(fumo|dice|cornell|doom|sandbox|rhythm|fluid|physics)$")
    message(FATAL_ERROR "ZIG_START_DEMO must be fumo, dice, cornell, doom, sandbox, rhythm, fluid or physics")
endif()
if(NOT ZIG_PIXEL_SCALE MATCHES "^(2|4)$")
    message(FATAL_ERROR "ZIG_PIXEL_SCALE must be 2 or 4")
endif()

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
execute_process(COMMAND "${PYTHON}" "${CMAKE_SOURCE_DIR}/scripts/fetch-doom-engine.py"
                RESULT_VARIABLE doom_source_result)
if(NOT doom_source_result EQUAL 0)
    message(FATAL_ERROR "DoomGeneric sources unavailable; run scripts/fetch-doom-engine.py")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${CMAKE_SOURCE_DIR}/dependencies.json"
    "${CMAKE_SOURCE_DIR}/scripts/fetch-doom-engine.py"
    "${CMAKE_SOURCE_DIR}/components/doom_engine/sources.txt"
    "${CMAKE_SOURCE_DIR}/components/doom_engine/patches/esp32.patch")
project(jirai_badge)
set(DOOM_WAD_PATH "${CMAKE_SOURCE_DIR}/.local/assets/doom1.wad" CACHE FILEPATH "Verified Doom shareware IWAD")
execute_process(COMMAND "${PYTHON}" "${CMAKE_SOURCE_DIR}/scripts/fetch-doom.py" --output "${DOOM_WAD_PATH}"
                RESULT_VARIABLE doom_asset_result)
if(NOT doom_asset_result EQUAL 0)
    message(FATAL_ERROR "Doom shareware IWAD unavailable; run scripts/fetch-doom.py")
endif()
esptool_py_flash_target_image(flash doom_wad 0x210000 "${DOOM_WAD_PATH}")
