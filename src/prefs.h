#ifndef PREFS_H
#define PREFS_H

#include <stdbool.h>
#include <sys/types.h>

// The settings domain shared with byper.app. Both programs read and write the
// same keys in com.gefaass.byper, so a change made in one is visible to the
// other. There is no parallel config file and no second set of key names.
#define BYPER_PREFS_DOMAIN "com.gefaass.byper"

// Keys, spelled exactly as byper.app spells them in BatteryMonitor.swift.
#define BYP_KEY_AUTO_CAFFEINE_BUNDLE_IDS    "byp_auto_caffeine_bundle_ids"
#define BYP_KEY_AUTO_CAFFEINE_ON_BYPASS     "byp_auto_caffeine_on_bypass"
#define BYP_KEY_AUTO_CAFFEINE_ON_CHARGER    "byp_auto_caffeine_on_charger"
#define BYP_KEY_AUTO_CAFFEINE_ON_LID_CLOSE  "byp_auto_caffeine_on_lid_close"
#define BYP_KEY_AUTO_CAFFEINE_PER_APP       "byp_auto_caffeine_per_app"
#define BYP_KEY_AUTO_HOLD_AT_LOGIN      "byp_auto_hold_at_login"
#define BYP_KEY_AUTO_HOLD_ON_DISPLAY    "byp_auto_hold_on_display"
#define BYP_KEY_AUTO_HOLD_ON_PLUG       "byp_auto_hold_on_plug"
#define BYP_KEY_AUTO_LPM_BUNDLE_IDS     "byp_auto_lpm_bundle_ids"
#define BYP_KEY_CACHED_INSTALLED_APPS   "byp_cached_installed_apps"
#define BYP_KEY_CAFFEINE_ALWAYS_ON      "byp_caffeine_always_on"
#define BYP_KEY_DISABLE_BYPASS_ON_QUIT  "byp_disable_bypass_on_quit"
#define BYP_KEY_MASTER_LEVEL            "byp_master_level"
#define BYP_KEY_POWER_MODE              "byp_power_mode"
#define BYP_KEY_RESUME_BYPASS_ON_LAUNCH "byp_resume_bypass_on_launch"

// Captures the uid that invoked the binary. Call this before setuid(0), or the
// SUID path loses the only record of which user's settings to read.
void prefs_init(uid_t invoking_uid);

// The user whose settings domain is read and written. SUDO_USER wins, then the
// invoking uid, then root.
const char *prefs_user(void);
const char *prefs_user_home(void);
uid_t prefs_user_uid(void);
gid_t prefs_user_gid(void);

bool prefs_get_bool(const char *key, bool fallback);
bool prefs_set_bool(const char *key, bool value);

double prefs_get_double(const char *key, double fallback);
bool prefs_set_double(const char *key, double value);

// Returns a malloc'd copy, or NULL when the key is absent or not a string.
char *prefs_copy_string(const char *key);
bool prefs_set_string(const char *key, const char *value);

// Returns the number of entries and fills values with a malloc'd array of
// malloc'd strings. Free with prefs_free_string_array.
int prefs_copy_string_array(const char *key, char ***values);
void prefs_free_string_array(char **values, int count);
bool prefs_set_string_array(const char *key, const char *const *values, int count);
bool prefs_string_array_contains(const char *key, const char *value);

bool prefs_remove(const char *key);

// byp_cached_installed_apps is the app's own cache of installed apps. The CLI
// reads it to resolve a bundle id to a display name and never writes it.
char *prefs_copy_installed_app_name(const char *bundle_id);
bool prefs_installed_apps_known(void);

#endif // PREFS_H
