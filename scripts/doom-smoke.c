// SPDX-License-Identifier: GPL-2.0-or-later
#include "doomgeneric.h"
#include "doomstat.h"
#include "doomkeys.h"
#include "p_mobj.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint32_t ticks = 1, frames, desired, emitted;
static uint32_t presses, releases, first_hash, last_hash;
static const unsigned char codes[] = { KEY_UPARROW, KEY_RIGHTARROW, KEY_FIRE, KEY_USE, KEY_ESCAPE };
void DG_Init(void) {}
void DG_SetWindowTitle(const char *title) { (void)title; }
uint32_t DG_GetTicksMs(void) { return ticks; }
void DG_SleepMs(uint32_t ms) { ticks += ms ? ms : 1; }
int DG_GetKey(int *pressed, unsigned char *key)
{
    uint32_t released = emitted & ~desired;
    uint32_t changed = released ? released : desired & ~emitted;
    if (!changed) return 0;
    unsigned bit = 0;
    while (!(changed & (1u << bit))) bit++;
    emitted ^= 1u << bit;
    *pressed = !released;
    *key = codes[bit];
    if (*pressed) presses++; else releases++;
    return 1;
}
void DG_DrawFrame(void)
{
    const uint16_t *image = (const uint16_t *)DG_ScreenBuffer;
    uint32_t hash = 2166136261u;
    for (unsigned i = 0; i < 64000; i++) hash = (hash ^ image[i]) * 16777619u;
    if (!frames) first_hash = hash;
    last_hash = hash;
    frames++;
}
int main(int argc, char **argv)
{
    if (argc != 3 && argc != 4) return 2;
    char *doom_argv[] = { "doom-smoke", "-iwad", argv[1], "-mb", "8", "-nosound", "-nogui",
                          "-gfxmode", "rgb565", "-warp", "1", "1", "-skill", "2" };
    doomgeneric_Create(sizeof(doom_argv) / sizeof(doom_argv[0]), doom_argv);
    if (!players[consoleplayer].mo) return 3;
    fixed_t first_x = players[consoleplayer].mo->x, first_y = players[consoleplayer].mo->y;
    int first_ammo = players[consoleplayer].ammo[am_clip];
    for (int step = 0; step < 160; step++) {
        desired = step < 35 ? 1 : step < 60 ? 2 : step < 75 ? 4 : step < 80 ? 8 : 0;
        ticks += 35;
        doomgeneric_Tick();
    }
    if (players[consoleplayer].ammo[am_clip] >= first_ammo) return 6;
    for (int toggle = 0; toggle < 2; toggle++) {
        for (int step = 0; step < 4; step++) {
            desired = step < 2 ? 16 : 0;
            ticks += 35;
            doomgeneric_Tick();
        }
        if (menuactive != (toggle == 0)) return 7;
    }
    const uint16_t *image = (const uint16_t *)DG_ScreenBuffer;
    unsigned ink = 0;
    for (unsigned i = 0; i < 64000; i++) if (image[i]) ink++;
    int moved = first_x != players[consoleplayer].mo->x || first_y != players[consoleplayer].mo->y;
    if (!moved || frames < 160 || first_hash == last_hash || ink < 6400 || presses != 6 || releases != 6 || emitted)
        return 4;
    FILE *output = fopen(argv[2], "wb");
    if (!output) return 5;
    // Correct original 320x200 non-square pixels to 4:3, as the device UI does.
    fprintf(output, "P6\n320 240\n255\n");
    for (unsigned y = 0; y < 240; y++) for (unsigned x = 0; x < 320; x++) {
        uint16_t p = image[(y * 200 / 240) * 320 + x];
        unsigned char rgb[] = { ((p >> 11) & 31) * 255 / 31, ((p >> 5) & 63) * 255 / 63, (p & 31) * 255 / 31 };
        fwrite(rgb, 1, 3, output);
    }
    fclose(output);
    if (argc == 4) {
        FILE *raw = fopen(argv[3], "wb");
        if (!raw) return 5;
        for (unsigned i = 0; i < 64000; i++) {
            const unsigned char bytes[] = { image[i] & 255, image[i] >> 8 };
            if (fwrite(bytes, 1, 2, raw) != 2) { fclose(raw); return 5; }
        }
        if (fclose(raw) != 0) return 5;
    }
    printf("DOOM SMOKE PASS: frames=%u, moved=%d, down/up=%u/%u, ink=%u/64000, hashes=%08x/%08x\n",
           frames, moved, presses, releases, ink, first_hash, last_hash);
    return 0;
}
