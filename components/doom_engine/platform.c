// SPDX-License-Identifier: GPL-2.0-or-later
#include "badge_doom.h"
#include "doomgeneric.h"
#include "doomstat.h"
#include "w_file.h"
#include "esp_partition.h"
#include "esp_log.h"
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WAD_BYTES 4196020u
static const uint8_t *wad_base;
static esp_partition_mmap_handle_t wad_mapping;
static jmp_buf failure_boundary;
static char failure_message[160];
static int started;

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

_Noreturn void badge_doom_fatal(const char *message)
{
    snprintf(failure_message, sizeof(failure_message), "%s", message);
    ESP_LOGE("doom", "%s", failure_message);
    longjmp(failure_boundary, 1);
}

const char *badge_doom_error(void) { return failure_message; }
int badge_doom_tic(void) { return gametic; }

int badge_doom_start(void)
{
    if (started) return -1; // Engine globals are persistent, never reinitialize.
    if (setjmp(failure_boundary)) return -1;
    const esp_partition_t *partition = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, 0x40, "doom_wad");
    if (!partition || partition->size < WAD_BYTES) badge_doom_fatal("Missing doom_wad partition");
    if (esp_partition_mmap(partition, 0, WAD_BYTES, ESP_PARTITION_MMAP_DATA,
                           (const void **)&wad_base, &wad_mapping) != ESP_OK)
        badge_doom_fatal("Unable to map Doom IWAD");
    if (memcmp(wad_base, "IWAD", 4)) badge_doom_fatal("Missing Doom shareware data; run idf flash");
    uint32_t count = le32(wad_base + 4), directory = le32(wad_base + 8);
    if (directory > WAD_BYTES || count > (WAD_BYTES - directory) / 16)
        badge_doom_fatal("Corrupt IWAD directory");
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *entry = wad_base + directory + i * 16;
        uint32_t offset = le32(entry), size = le32(entry + 4);
        if (offset > WAD_BYTES || size > WAD_BYTES - offset) badge_doom_fatal("Corrupt IWAD lump");
    }
    ESP_LOGI("doom", "IWAD mapped: %u bytes, %lu lumps, offset=0x%lx", WAD_BYTES,
             (unsigned long)count, (unsigned long)partition->address);
    static char *argv[] = { "badge-doom", "-iwad", "doom1.wad", "-mb", "4", "-nosound",
                            "-nogui", "-gfxmode", "rgb565", "-warp", "1", "1", "-skill", "2" };
    doomgeneric_Create(sizeof(argv) / sizeof(argv[0]), argv);
    started = 1;
    return 0;
}

int badge_doom_tick(void)
{
    if (setjmp(failure_boundary)) return -1;
    doomgeneric_Tick();
    return 0;
}

extern wad_file_class_t stdc_wad_file;
static wad_file_t *open_wad(char *path)
{
    if (!wad_base || strcmp(path, "doom1.wad")) return NULL;
    wad_file_t *file = calloc(1, sizeof(*file));
    if (file) {
        file->file_class = &stdc_wad_file;
        file->mapped = (byte *)wad_base;
        file->length = WAD_BYTES;
    }
    return file;
}
static void close_wad(wad_file_t *file) { free(file); }
static size_t read_wad(wad_file_t *file, unsigned int offset, void *buffer, size_t length)
{
    if (offset >= file->length) return 0;
    if (length > file->length - offset) length = file->length - offset;
    memcpy(buffer, file->mapped + offset, length);
    return length;
}
wad_file_class_t stdc_wad_file = { open_wad, close_wad, read_wad };
