if(CMAKE_HOST_WIN32)
    set(ZIG_BIN "${ZIG_DIR}/zig.exe")
else()
    set(ZIG_BIN "${ZIG_DIR}/zig")
endif()
string(JSON HASH_SUM ERROR_VARIABLE HASH_ERROR GET "${DEPENDENCY_PINS}" zig archives "${ZIG_TRIPLET}")
if(HASH_ERROR)
    message(FATAL_ERROR "No pinned Zig archive for host ${ZIG_TRIPLET}")
endif()
if(NOT EXISTS "${ZIG_BIN}")
    string(JSON ZIG_REPOSITORY GET "${DEPENDENCY_PINS}" zig repository)
    set(ZIG_URL "${ZIG_REPOSITORY}/releases/download/${ZIG_PINNED_VERSION}/zig-relsafe-${ZIG_TRIPLET}.${ARCHIVE_EXT}")
    message(STATUS "Downloading pinned Zig: ${ZIG_URL}")
    file(DOWNLOAD "${ZIG_URL}" "${ZIG_ARCHIVE}"
        TLS_VERIFY ON EXPECTED_HASH SHA256=${HASH_SUM}
        STATUS download_status LOG download_log)
    list(GET download_status 0 dl_code)
    if(NOT dl_code EQUAL 0)
        message(FATAL_ERROR "Zig download failed: ${download_log}")
    endif()
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E tar xf "${ZIG_ARCHIVE}"
        WORKING_DIRECTORY "${ZIG_TOOLCHAIN_ROOT}"
        RESULT_VARIABLE extract_result)
    if(NOT extract_result EQUAL 0)
        message(FATAL_ERROR "Zig extraction failed: ${extract_result}")
    endif()
endif()
message(STATUS "Using cached pinned Zig: ${ZIG_BIN}")
