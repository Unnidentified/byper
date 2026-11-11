#include "prefs.h"

#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static uid_t g_invoking_uid = 0;
static bool g_resolved = false;
static char g_user[256] = "root";
static char g_home[1024] = "/var/root";
static uid_t g_uid = 0;
static gid_t g_gid = 0;

static void prefs_resolve(void) {
    if (g_resolved) return;
    g_resolved = true;

    const char *name = NULL;
    const char *sudo_user = getenv("SUDO_USER");
    if (sudo_user && sudo_user[0] && strcmp(sudo_user, "root") != 0) {
        name = sudo_user;
    } else if (g_invoking_uid != 0) {
        struct passwd *pw = getpwuid(g_invoking_uid);
        if (pw && pw->pw_name) name = pw->pw_name;
    }
    if (!name) {
        struct passwd *pw = getpwuid(getuid());
        if (pw && pw->pw_name) name = pw->pw_name;
    }
    if (!name) name = "root";

    struct passwd *pw = getpwnam(name);
    if (!pw) pw = getpwuid(getuid());
    if (!pw) return;

    snprintf(g_user, sizeof(g_user), "%s", pw->pw_name);
    snprintf(g_home, sizeof(g_home), "%s", pw->pw_dir ? pw->pw_dir : "/");
    g_uid = pw->pw_uid;
    g_gid = pw->pw_gid;
}

void prefs_init(uid_t invoking_uid) {
    g_invoking_uid = invoking_uid;
    g_resolved = false;
    prefs_resolve();
}

const char *prefs_user(void) {
    prefs_resolve();
    return g_user;
}

const char *prefs_user_home(void) {
    prefs_resolve();
    return g_home;
}

uid_t prefs_user_uid(void) {
    prefs_resolve();
    return g_uid;
}

gid_t prefs_user_gid(void) {
    prefs_resolve();
    return g_gid;
}

static CFStringRef prefs_make_string(const char *value) {
    return CFStringCreateWithCString(kCFAllocatorDefault, value, kCFStringEncodingUTF8);
}

static CFPropertyListRef prefs_copy_value(const char *key) {
    prefs_resolve();
    CFStringRef app = prefs_make_string(BYPER_PREFS_DOMAIN);
    CFStringRef cf_key = prefs_make_string(key);
    CFStringRef user = prefs_make_string(g_user);
    if (!app || !cf_key || !user) {
        if (app) CFRelease(app);
        if (cf_key) CFRelease(cf_key);
        if (user) CFRelease(user);
        return NULL;
    }
    CFPropertyListRef value = CFPreferencesCopyValue(cf_key, app, user, kCFPreferencesAnyHost);
    CFRelease(app);
    CFRelease(cf_key);
    CFRelease(user);
    return value;
}

// Writes go through /usr/bin/defaults as the settings owner. That is the same
// path `defaults write` takes, so the app's cfprefsd sees the change at once.
// The child drops to the settings owner first, so a SUID run never writes into
// root's domain by accident.
static bool prefs_run_defaults(char *const argv[]) {
    prefs_resolve();
    pid_t pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        if (geteuid() == 0 && g_uid != 0) {
            if (setgid(g_gid) != 0) _exit(126);
            if (setuid(g_uid) != 0) _exit(126);
        }
        execv("/usr/bin/defaults", argv);
        _exit(127);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return false;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

bool prefs_get_bool(const char *key, bool fallback) {
    CFPropertyListRef value = prefs_copy_value(key);
    if (!value) return fallback;
    bool result = fallback;
    CFTypeID type = CFGetTypeID(value);
    if (type == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    } else if (type == CFNumberGetTypeID()) {
        int number = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number)) result = (number != 0);
    }
    CFRelease(value);
    return result;
}

bool prefs_set_bool(const char *key, bool value) {
    char *argv[] = {
        (char *)"defaults", (char *)"write", (char *)BYPER_PREFS_DOMAIN,
        (char *)key, (char *)"-bool", (char *)(value ? "true" : "false"), NULL
    };
    return prefs_run_defaults(argv);
}

double prefs_get_double(const char *key, double fallback) {
    CFPropertyListRef value = prefs_copy_value(key);
    if (!value) return fallback;
    double result = fallback;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &result);
    }
    CFRelease(value);
    return result;
}

bool prefs_set_double(const char *key, double value) {
    char buffer[64];
    snprintf(buffer, sizeof(buffer), "%.6f", value);
    char *argv[] = {
        (char *)"defaults", (char *)"write", (char *)BYPER_PREFS_DOMAIN,
        (char *)key, (char *)"-float", buffer, NULL
    };
    return prefs_run_defaults(argv);
}

char *prefs_copy_string(const char *key) {
    CFPropertyListRef value = prefs_copy_value(key);
    if (!value) return NULL;
    char *result = NULL;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringRef string = (CFStringRef)value;
        CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
        if (size > 0) {
            result = (char *)malloc((size_t)size);
            if (result && !CFStringGetCString(string, result, size, kCFStringEncodingUTF8)) {
                free(result);
                result = NULL;
            }
        }
    }
    CFRelease(value);
    return result;
}

bool prefs_set_string(const char *key, const char *value) {
    char *argv[] = {
        (char *)"defaults", (char *)"write", (char *)BYPER_PREFS_DOMAIN,
        (char *)key, (char *)"-string", (char *)value, NULL
    };
    return prefs_run_defaults(argv);
}

int prefs_copy_string_array(const char *key, char ***values) {
    if (values) *values = NULL;
    CFPropertyListRef value = prefs_copy_value(key);
    if (!value) return 0;
    if (CFGetTypeID(value) != CFArrayGetTypeID()) {
        CFRelease(value);
        return 0;
    }
    CFArrayRef array = (CFArrayRef)value;
    CFIndex total = CFArrayGetCount(array);
    char **out = (char **)calloc((size_t)(total > 0 ? total : 1), sizeof(char *));
    if (!out) {
        CFRelease(value);
        return 0;
    }
    int count = 0;
    for (CFIndex i = 0; i < total; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(array, i);
        if (!item || CFGetTypeID(item) != CFStringGetTypeID()) continue;
        char buffer[1024];
        if (!CFStringGetCString((CFStringRef)item, buffer, sizeof(buffer), kCFStringEncodingUTF8)) continue;
        out[count] = strdup(buffer);
        if (out[count]) count++;
    }
    CFRelease(value);
    if (values) *values = out;
    return count;
}

void prefs_free_string_array(char **values, int count) {
    if (!values) return;
    for (int i = 0; i < count; i++) free(values[i]);
    free(values);
}

bool prefs_set_string_array(const char *key, const char *const *values, int count) {
    int slots = 6 + (count > 0 ? count : 0);
    char **argv = (char **)calloc((size_t)slots, sizeof(char *));
    if (!argv) return false;
    int index = 0;
    argv[index++] = (char *)"defaults";
    argv[index++] = (char *)"write";
    argv[index++] = (char *)BYPER_PREFS_DOMAIN;
    argv[index++] = (char *)key;
    argv[index++] = (char *)"-array";
    for (int i = 0; i < count; i++) argv[index++] = (char *)values[i];
    argv[index] = NULL;
    bool ok = prefs_run_defaults(argv);
    free(argv);
    return ok;
}

bool prefs_string_array_contains(const char *key, const char *value) {
    if (!value) return false;
    char **values = NULL;
    int count = prefs_copy_string_array(key, &values);
    bool found = false;
    for (int i = 0; i < count && !found; i++) {
        if (values[i] && strcmp(values[i], value) == 0) found = true;
    }
    prefs_free_string_array(values, count);
    return found;
}

bool prefs_remove(const char *key) {
    char *argv[] = {
        (char *)"defaults", (char *)"delete", (char *)BYPER_PREFS_DOMAIN,
        (char *)key, NULL
    };
    return prefs_run_defaults(argv);
}

char *prefs_copy_installed_app_name(const char *bundle_id) {
    if (!bundle_id) return NULL;
    CFPropertyListRef value = prefs_copy_value(BYP_KEY_CACHED_INSTALLED_APPS);
    if (!value) return NULL;
    char *result = NULL;
    if (CFGetTypeID(value) == CFArrayGetTypeID()) {
        CFArrayRef array = (CFArrayRef)value;
        CFIndex total = CFArrayGetCount(array);
        for (CFIndex i = 0; i < total && !result; i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(array, i);
            if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
            CFDictionaryRef entry = (CFDictionaryRef)item;
            CFStringRef identifier = (CFStringRef)CFDictionaryGetValue(entry, CFSTR("bundleID"));
            if (!identifier || CFGetTypeID(identifier) != CFStringGetTypeID()) continue;
            char buffer[512];
            if (!CFStringGetCString(identifier, buffer, sizeof(buffer), kCFStringEncodingUTF8)) continue;
            if (strcmp(buffer, bundle_id) != 0) continue;
            CFStringRef name = (CFStringRef)CFDictionaryGetValue(entry, CFSTR("name"));
            if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
                char name_buffer[512];
                if (CFStringGetCString(name, name_buffer, sizeof(name_buffer), kCFStringEncodingUTF8)) {
                    result = strdup(name_buffer);
                }
            }
        }
    }
    CFRelease(value);
    return result;
}

bool prefs_installed_apps_known(void) {
    CFPropertyListRef value = prefs_copy_value(BYP_KEY_CACHED_INSTALLED_APPS);
    if (!value) return false;
    bool known = false;
    if (CFGetTypeID(value) == CFArrayGetTypeID()) {
        known = CFArrayGetCount((CFArrayRef)value) > 0;
    }
    CFRelease(value);
    return known;
}
