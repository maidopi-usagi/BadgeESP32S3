file(READ "${CMAKE_CURRENT_LIST_DIR}/../../dependencies.json" DOOM_PINS)
string(JSON DOOM_PATH GET "${DOOM_PINS}" doomgeneric path)
get_filename_component(DOOM_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../${DOOM_PATH}" ABSOLUTE)
file(STRINGS "${CMAKE_CURRENT_LIST_DIR}/sources.txt" DOOM_NAMES)
set(DOOM_SRCS "platform.c")
foreach(name IN LISTS DOOM_NAMES)
    list(APPEND DOOM_SRCS "${DOOM_ROOT}/${name}")
endforeach()
idf_component_register(SRCS ${DOOM_SRCS} INCLUDE_DIRS "include" "${DOOM_ROOT}"
                       REQUIRES esp_partition esp_timer esp_psram
                       LDFRAGMENTS "linker.lf")
idf_build_get_property(DOOM_PYTHON PYTHON)
file(GLOB DOOM_HEADERS "${DOOM_ROOT}/*.h")
set(DOOM_FETCHED_SRCS ${DOOM_SRCS})
list(REMOVE_ITEM DOOM_FETCHED_SRCS "platform.c")
add_custom_target(badge_doom_sources
    COMMAND "${DOOM_PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/../../scripts/fetch-doom-engine.py"
    BYPRODUCTS ${DOOM_FETCHED_SRCS} ${DOOM_HEADERS}
    VERBATIM)
add_dependencies(${COMPONENT_LIB} badge_doom_sources)
target_compile_definitions(${COMPONENT_LIB} PUBLIC NORMALUNIX LINUX
    DOOMGENERIC_RESX=320 DOOMGENERIC_RESY=200 DOOMGENERIC_FB_BYTES_PER_PIXEL=2)
# Original Doom uses type-punning and pre-C99 conventions.
target_compile_options(${COMPONENT_LIB} PRIVATE -fno-strict-aliasing
    -Wno-error -Wno-error=format-truncation -Wno-error=dangling-pointer
    -Wno-unused-but-set-parameter -Wno-unused-variable -Wno-unused-but-set-variable
    -Wno-pointer-sign -Wno-missing-field-initializers)
