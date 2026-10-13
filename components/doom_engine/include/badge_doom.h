#pragma once
#include <stdint.h>

int badge_doom_start(void);
int badge_doom_tick(void);
const char *badge_doom_error(void);
_Noreturn void badge_doom_fatal(const char *message);
int badge_doom_tic(void);
