# Use a reviewed, version-controlled esp-rs header, never mutable master.
string(JSON BINDINGS_HEADER GET "${DEPENDENCY_PINS}" esp_idf_sys header)
string(JSON BINDINGS_SHA256 GET "${DEPENDENCY_PINS}" esp_idf_sys sha256)
set(BINDINGS_ESP_RS "${CMAKE_SOURCE_DIR}/${BINDINGS_HEADER}")
file(SHA256 "${BINDINGS_ESP_RS}" ACTUAL_BINDINGS_SHA256)
if(NOT ACTUAL_BINDINGS_SHA256 STREQUAL BINDINGS_SHA256)
    message(FATAL_ERROR "esp-idf-sys header checksum differs from dependencies.json")
endif()
list(APPEND INCLUDE_DIRS
    "${ZIG_IDF_ROOT}/include"
    "${CMAKE_SOURCE_DIR}/third_party/esp-idf-sys")
message(STATUS "Using pinned esp-idf-sys header: ${BINDINGS_ESP_RS}")
