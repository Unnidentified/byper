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

// The lid switch, read from AppleClamshellState on IOPMrootDomain. False on a
// machine with no lid.
bool automation_lid_closed(void);

// SleepDisabled on IOPMrootDomain, the kernel's own answer to "may this machine
// sleep". pmset -a disablesleep writes it and it is the only switch that
// overrides a lid close. Readable without root.
bool automation_sleep_disabled(void);

// Writes SleepDisabled through pmset and reads it back. Returns true only when
// the flag matches the requested state: pmset exits 0 when it refuses for lack
// of root, so the exit code is never trusted.
bool automation_set_sleep_disabled(bool disabled);

// The armed caffeinate conditions, in the words the app's dropdown uses, joined
// with " + ", or "off" when none is armed.
const char *caffeinate_armed_summary(void);

// True when caffeinate should be running right now: the manual switch is on, or
// any armed condition is satisfied. The conditions are independent, so this is a
// plain OR over the switch and every armed condition's trigger.
bool automation_caffeinate_wanted(const BatteryInfo *info);

// Releases the bypass hold on process exit when byp_disable_bypass_on_quit is
// on. Registered with atexit by the automation runner, the only process that
// can own a hold across time.
void automation_off_on_exit(void);

// Runs the automations until SIGINT or SIGTERM. Returns a process exit code.
int automation_watch(const AutomationWatchOptions *options);

// True when a byper watch process is alive.
bool automation_watch_running(void);

#endif // AUTOMATION_H
