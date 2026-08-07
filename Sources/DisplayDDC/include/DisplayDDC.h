#ifndef PYPY_DISPLAY_DDC_H
#define PYPY_DISPLAY_DDC_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

bool PypyDDCReadBrightness(
    CGDirectDisplayID displayID,
    uint16_t *currentValue,
    uint16_t *maximumValue
);

bool PypyDDCSetBrightness(CGDirectDisplayID displayID, uint16_t value);

#endif
