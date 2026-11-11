#ifndef HOLD_H
#define HOLD_H

#include <stdbool.h>

// Engage the bypass hold at the current state of charge and record it in
// /tmp/byp.state. Defined in main.c and shared with the automation runner so
// both paths leave the same marker behind.
bool engage_bypass_at_any_percentage(void);

// Release the hold and resume charging, clearing /tmp/byp.state.
bool disable_bypass_and_resume_charging(void);

#endif // HOLD_H
