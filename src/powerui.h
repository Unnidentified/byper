#ifndef POWERUI_H
#define POWERUI_H

#include <stdbool.h>

typedef struct {
    bool isSupported;
    bool isMCLEnabled;
    bool isOBCEngaged;
    int currentLimit;
    bool isEnabled;
    bool isTemporarilyDisabled;
} NativeHoldStatus;

bool powerui_init(void);
bool powerui_get_status(NativeHoldStatus *status);
bool powerui_enable_hold(void);
bool powerui_disable_hold(void);
bool powerui_charge_to_full_now(void);

#endif // POWERUI_H
