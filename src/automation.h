#ifndef AUTOMATION_H
#define AUTOMATION_H

#include <stdbool.h>

#include "battery.h"

typedef struct {
    bool quiet;
    bool force;
} AutomationWatchOptions;

// True when the hardware reports a bypass hold: AC attached, charging stopped,
// near zero flow, and either the hold flag or a full battery resting.
bool automation_hold_active(const BatteryInfo *info);

// Platform probes.
bool automation_app_running(void);
bool automation_external_display_connected(void);
char *automation_frontmost_bundle_id(void);
bool automation_low_power_mode(void);
bool automation_set_low_power_mode(bool enabled);

// Caffeinate: a detached /usr/bin/caffeinate -d -i tracked by pid file, so the
// hold survives the command that started it and can be stopped later.
bool automation_caffeinate_running(void);
bool automation_caffeinate_start(void);
bool automation_caffeinate_stop(void);

// Releases the bypass hold on process exit when byp_disable_bypass_on_quit is
// on. Registered with atexit by the automation runner, the only process that
// can own a hold across time.
void automation_off_on_exit(void);

// Runs the automations until SIGINT or SIGTERM. Returns a process exit code.
int automation_watch(const AutomationWatchOptions *options);

// True when a byper watch process is alive.
bool automation_watch_running(void);

#endif // AUTOMATION_H
