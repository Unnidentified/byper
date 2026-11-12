#include "automation.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <notify.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "hold.h"
#include "prefs.h"

#define WATCH_TICK_MS       200
#define WATCH_TICKS         10
#define LPM_RETRY_SECONDS   5

static volatile sig_atomic_t g_watch_running = 0;

// State files are per settings owner, so a SUID run and a dev build run by the
// same user share them, and two users never fight over one lock.
static void caffeinate_pid_path(char *out, size_t size) {
    snprintf(out, size, "/tmp/byp_caffeine.%d.pid", (int)prefs_user_uid());
}

static void runner_pid_path(char *out, size_t size) {
    snprintf(out, size, "/tmp/byp_auto_run.%d.pid", (int)prefs_user_uid());
}

static void runner_lock_path(char *out, size_t size) {
    snprintf(out, size, "/tmp/byp_auto_run.%d.lock", (int)prefs_user_uid());
}

bool automation_hold_active(const BatteryInfo *info) {
    if (!info || !info->acAttached) return false;
    if (info->isCharging) return false;
    if (abs(info->amperage) >= 100) return false;
    if ((info->notChargingReason & 0x01000000) != 0) return true;
    // At a full battery the hold flag never sets: idle and full is the goal
    // state, so a recorded hold plus a resting battery counts as holding.
    return info->percentage >= 95 && access("/tmp/byp.state", F_OK) == 0;
}

// MARK: - Process and display probes

static bool path_is_app(const char *path) {
    return path && strstr(path, "/byper.app/Contents/MacOS/byper") != NULL;
}

bool automation_app_running(void) {
    int capacity = 1024;
    pid_t *pids = NULL;
    int count = 0;
    for (int attempt = 0; attempt < 4; attempt++) {
        free(pids);
        pids = (pid_t *)calloc((size_t)capacity, sizeof(pid_t));
        if (!pids) return false;
        count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
        if (count < capacity) break;
        capacity *= 2;
    }
    bool found = false;
    for (int i = 0; i < count && !found; i++) {
        if (pids[i] <= 0) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        if (path_is_app(path)) found = true;
    }
    free(pids);
    return found;
}

bool automation_external_display_connected(void) {
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return false;
    CGDirectDisplayID *displays = (CGDirectDisplayID *)calloc(count, sizeof(CGDirectDisplayID));
    if (!displays) return false;
    bool found = false;
    if (CGGetOnlineDisplayList(count, displays, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            if (!CGDisplayIsBuiltin(displays[i])) {
                found = true;
                break;
            }
        }
    }
    free(displays);
    return found;
}

static bool bundle_id_for_pid(pid_t pid, char *out, size_t size) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return false;
    char *marker = strstr(path, "/Contents/MacOS/");
    if (!marker) return false;
    *marker = '\0';

    char plist_path[PROC_PIDPATHINFO_MAXSIZE + 32];
    snprintf(plist_path, sizeof(plist_path), "%s/Contents/Info.plist", path);

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)plist_path, (CFIndex)strlen(plist_path), false);
    if (!url) return false;
    CFReadStreamRef stream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
    CFRelease(url);
    if (!stream) return false;

    bool found = false;
    if (CFReadStreamOpen(stream)) {
        CFPropertyListRef plist = CFPropertyListCreateWithStream(
            kCFAllocatorDefault, stream, 0, kCFPropertyListImmutable, NULL, NULL);
        CFReadStreamClose(stream);
        if (plist) {
            if (CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
                CFStringRef identifier = (CFStringRef)CFDictionaryGetValue(
                    (CFDictionaryRef)plist, CFSTR("CFBundleIdentifier"));
                if (identifier && CFGetTypeID(identifier) == CFStringGetTypeID()) {
                    found = CFStringGetCString(identifier, out, (CFIndex)size, kCFStringEncodingUTF8);
                }
            }
            CFRelease(plist);
        }
    }
    CFRelease(stream);
    return found;
}

// The frontmost real window owner, the same rule the app uses: the first
// normal level window with real bounds. Menu bar items, popovers and the
// desktop sit outside layer 0 and are skipped.
char *automation_frontmost_bundle_id(void) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!windows) return NULL;
    char *result = NULL;
    CFIndex total = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < total && !result; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(windows, i);
        if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
        CFDictionaryRef window = (CFDictionaryRef)item;

        CFNumberRef layer = (CFNumberRef)CFDictionaryGetValue(window, kCGWindowLayer);
        int layer_value = -1;
        if (!layer || CFGetTypeID(layer) != CFNumberGetTypeID()) continue;
        if (!CFNumberGetValue(layer, kCFNumberIntType, &layer_value) || layer_value != 0) continue;

        CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue(window, kCGWindowBounds);
        if (!bounds || CFGetTypeID(bounds) != CFDictionaryGetTypeID()) continue;
        CGRect rect;
        if (!CGRectMakeWithDictionaryRepresentation(bounds, &rect)) continue;
        if (rect.size.width <= 0 || rect.size.height <= 0) continue;

        CFNumberRef owner = (CFNumberRef)CFDictionaryGetValue(window, kCGWindowOwnerPID);
        int pid = 0;
        if (!owner || CFGetTypeID(owner) != CFNumberGetTypeID()) continue;
        if (!CFNumberGetValue(owner, kCFNumberIntType, &pid) || pid <= 0) continue;

        char bundle[512];
        if (bundle_id_for_pid((pid_t)pid, bundle, sizeof(bundle))) result = strdup(bundle);
    }
    CFRelease(windows);
    return result;
}

bool automation_low_power_mode(void) {
    int token = 0;
    if (notify_register_check("com.apple.system.lowpowermode", &token) != NOTIFY_STATUS_OK) return false;
    uint64_t state = 0;
    bool enabled = false;
    if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) enabled = (state != 0);
    notify_cancel(token);
    return enabled;
}

bool automation_set_low_power_mode(bool enabled) {
    pid_t pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > STDERR_FILENO) close(devnull);
        }
        char *argv[] = {
            (char *)"/usr/bin/pmset", (char *)"-a", (char *)"lowpowermode",
            (char *)(enabled ? "1" : "0"), NULL
        };
        execv(argv[0], argv);
        _exit(127);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return false;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// MARK: - Caffeinate

static pid_t read_pid_file(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    char buffer[32];
    ssize_t length = read(fd, buffer, sizeof(buffer) - 1);
    close(fd);
    if (length <= 0) return 0;
    buffer[length] = '\0';
    return (pid_t)atoi(buffer);
}

static bool write_pid_file(const char *path, pid_t pid) {
    unlink(path);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
    if (fd < 0) return false;
    char buffer[32];
    int length = snprintf(buffer, sizeof(buffer), "%d\n", (int)pid);
    ssize_t written = write(fd, buffer, (size_t)length);
    close(fd);
    return written == (ssize_t)length;
}

static bool pid_is_caffeinate(pid_t pid) {
    if (pid <= 0) return false;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return false;
    return strcmp(path, "/usr/bin/caffeinate") == 0;
}

bool automation_caffeinate_running(void) {
    char path[128];
    caffeinate_pid_path(path, sizeof(path));
    pid_t pid = read_pid_file(path);
    if (pid <= 0) return false;
    if (pid_is_caffeinate(pid)) return true;
    unlink(path);
    return false;
}

bool automation_caffeinate_start(void) {
    if (automation_caffeinate_running()) return true;
    pid_t pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        setsid();
        if (geteuid() == 0 && prefs_user_uid() != 0) {
            if (setgid(prefs_user_gid()) != 0) _exit(126);
            if (setuid(prefs_user_uid()) != 0) _exit(126);
        }
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > STDERR_FILENO) close(devnull);
        }
        char *argv[] = { (char *)"/usr/bin/caffeinate", (char *)"-d", (char *)"-i", NULL };
        execv(argv[0], argv);
        _exit(127);
    }
    char path[128];
    caffeinate_pid_path(path, sizeof(path));
    if (!write_pid_file(path, pid)) {
        kill(pid, SIGTERM);
        return false;
    }
    usleep(150000);
    return automation_caffeinate_running();
}

bool automation_caffeinate_stop(void) {
    char path[128];
    caffeinate_pid_path(path, sizeof(path));
    pid_t pid = read_pid_file(path);
    unlink(path);
    if (pid <= 0) return true;
    if (!pid_is_caffeinate(pid)) return true;
    if (kill(pid, SIGTERM) != 0 && errno != ESRCH) return false;
    return true;
}

// AppleClamshellState on IOPMrootDomain is the lid switch: false with the lid
// open, true once it is shut. A desktop has no such property and reads false.
bool automation_lid_closed(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!service) return false;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (!value) return false;
    bool closed = false;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) closed = CFBooleanGetValue((CFBooleanRef)value);
    CFRelease(value);
    return closed;
}

// MARK: - Lid sleep

// SleepDisabled on IOPMrootDomain is the kernel's own answer to "may this
// machine sleep". pmset -a disablesleep writes it, and it is the only switch
// that overrides a lid close: the idle-sleep assertions do not, and powerd
// commits to Clamshell Sleep the instant the lid shuts, so the flag has to be
// in place before the lid moves. Reading it needs no root, which is what makes
// the read-back below possible.
bool automation_sleep_disabled(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!service) return false;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("SleepDisabled"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (!value) return false;
    bool disabled = false;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) disabled = CFBooleanGetValue((CFBooleanRef)value);
    CFRelease(value);
    return disabled;
}

bool automation_set_sleep_disabled(bool disabled) {
    pid_t pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > STDERR_FILENO) close(devnull);
        }
        char *argv[] = {
            (char *)"/usr/bin/pmset", (char *)"-a", (char *)"disablesleep",
            (char *)(disabled ? "1" : "0"), NULL
        };
        execv(argv[0], argv);
        _exit(127);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return false;
    }
    // pmset exits 0 when it refuses for lack of root, so the exit code says
    // nothing at all. Poll the flag instead, the same way the bypass engine
    // polls the hardware rather than trusting lldb.
    for (int attempt = 0; attempt < 20; attempt++) {
        if (automation_sleep_disabled() == disabled) return true;
        usleep(50000);
    }
    return automation_sleep_disabled() == disabled;
}

// The armed conditions, in the same words the app's dropdown uses, joined with
// " + ", or "off" when none is armed. The manual switch is reported separately
// because it is the always-on override, not a condition.
const char *caffeinate_armed_summary(void) {
    static char summary[128];
    static const struct { const char *key; const char *name; } conditions[] = {
        { BYP_KEY_AUTO_CAFFEINE_ON_BYPASS, "on bypass" },
        { BYP_KEY_AUTO_CAFFEINE_ON_LID_CLOSE, "on lid close" },
        { BYP_KEY_AUTO_CAFFEINE_ON_CHARGER, "on charger" },
        { BYP_KEY_AUTO_CAFFEINE_PER_APP, "per app" },
    };
    size_t used = 0;
    summary[0] = '\0';
    for (size_t i = 0; i < sizeof(conditions) / sizeof(conditions[0]); i++) {
        if (!prefs_get_bool(conditions[i].key, false)) continue;
        int written = snprintf(summary + used, sizeof(summary) - used, "%s%s",
                               used ? " + " : "", conditions[i].name);
        if (written < 0) break;
        used += (size_t)written;
        if (used >= sizeof(summary)) { used = sizeof(summary) - 1; break; }
    }
    return used ? summary : "off";
}

// True when caffeinate should be running right now: the manual switch is on, or
// any armed condition is satisfied. The four conditions are independent and
// combinable, so this is a plain OR and a condition releases as soon as its
// trigger drops. The runner and the app therefore agree on when caffeinate runs.
bool automation_caffeinate_wanted(const BatteryInfo *info) {
    if (prefs_get_bool(BYP_KEY_CAFFEINE_ALWAYS_ON, false)) return true;
    if (prefs_get_bool(BYP_KEY_AUTO_CAFFEINE_ON_BYPASS, false) && automation_hold_active(info)) return true;
    if (prefs_get_bool(BYP_KEY_AUTO_CAFFEINE_ON_LID_CLOSE, false) && automation_lid_closed()) return true;
    if (prefs_get_bool(BYP_KEY_AUTO_CAFFEINE_ON_CHARGER, false) && info->acAttached) return true;
    if (prefs_get_bool(BYP_KEY_AUTO_CAFFEINE_PER_APP, false)) {
        char *bundle = automation_frontmost_bundle_id();
        bool listed = bundle && prefs_string_array_contains(BYP_KEY_AUTO_CAFFEINE_BUNDLE_IDS, bundle);
        free(bundle);
        if (listed) return true;
    }
    return false;
}

// MARK: - Off on exit

void automation_off_on_exit(void) {
    if (!prefs_get_bool(BYP_KEY_DISABLE_BYPASS_ON_QUIT, false)) return;
    BatteryInfo info;
    if (!battery_get_info(&info)) return;
    if (!automation_hold_active(&info)) return;
    if (disable_bypass_and_resume_charging()) {
        printf("off on exit: bypass hold released\n");
    } else {
        printf("off on exit: bypass hold release not confirmed\n");
    }
    fflush(stdout);
}

// MARK: - Watch

bool automation_watch_running(void) {
    char pid_path[128];
    runner_pid_path(pid_path, sizeof(pid_path));
    pid_t pid = read_pid_file(pid_path);
    if (pid <= 0) return false;
    if (kill(pid, 0) != 0 && errno != EPERM) return false;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return false;
    const char *base = strrchr(path, '/');
    return base && strcmp(base + 1, "byper") == 0;
}

static void watch_signal(int sig) {
    (void)sig;
    g_watch_running = 0;
}

static void watch_clock(char *out, size_t size) {
    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);
    strftime(out, size, "%H:%M:%S", &parts);
}

static bool master_enabled(void) {
    return prefs_get_double(BYP_KEY_MASTER_LEVEL, 1.0) >= 0.999;
}

static void watch_log(const AutomationWatchOptions *options, const char *message) {
    if (options->quiet) return;
    char clock[16];
    watch_clock(clock, sizeof(clock));
    printf("[%s] %s\n", clock, message);
    fflush(stdout);
}

static void watch_engage(const char *reason, const AutomationWatchOptions *options, bool *warned_master) {
    BatteryInfo info;
    if (!battery_get_info(&info)) return;
    if (!info.acAttached) return;
    if (automation_hold_active(&info)) return;
    if (!master_enabled()) {
        if (!*warned_master) {
            fprintf(stderr, "master slider is down, automations are held off\n");
            *warned_master = true;
        }
        return;
    }
    bool engaged = engage_bypass_at_any_percentage();
    char message[128];
    snprintf(message, sizeof(message), "%s: bypass %s", reason, engaged ? "engaged" : "not confirmed");
    watch_log(options, message);
}

static void watch_print_settings(const AutomationWatchOptions *options) {
    if (options->quiet) return;
    printf("watching: plug=%s login=%s display=%s off-on-exit=%s master=%.2f\n",
           prefs_get_bool(BYP_KEY_AUTO_HOLD_ON_PLUG, false) ? "on" : "off",
           prefs_get_bool(BYP_KEY_AUTO_HOLD_AT_LOGIN, false) ? "on" : "off",
           prefs_get_bool(BYP_KEY_AUTO_HOLD_ON_DISPLAY, true) ? "on" : "off",
           prefs_get_bool(BYP_KEY_DISABLE_BYPASS_ON_QUIT, false) ? "on" : "off",
           prefs_get_double(BYP_KEY_MASTER_LEVEL, 1.0));
    char **apps = NULL;
    int count = prefs_copy_string_array(BYP_KEY_AUTO_LPM_BUNDLE_IDS, &apps);
    printf("auto lpm: %d app(s)\n", count);
    prefs_free_string_array(apps, count);
    printf("caffeinate: %s\n", caffeinate_armed_summary());
    fflush(stdout);
}

int automation_watch(const AutomationWatchOptions *options) {
    if (!options->force && automation_app_running()) {
        fprintf(stderr, "byper.app is running and already drives these automations\n");
        fprintf(stderr, "quit the app first, or pass --force to run both\n");
        return 1;
    }

    char lock_path[128];
    runner_lock_path(lock_path, sizeof(lock_path));
    int lock_fd = open(lock_path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (lock_fd < 0) {
        fprintf(stderr, "cannot open %s: %s\n", lock_path, strerror(errno));
        return 1;
    }
    if (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
        fprintf(stderr, "another byper auto run is already running\n");
        close(lock_fd);
        return 1;
    }
    char pid_path[128];
    runner_pid_path(pid_path, sizeof(pid_path));
    write_pid_file(pid_path, getpid());

    g_watch_running = 1;
    signal(SIGINT, watch_signal);
    signal(SIGTERM, watch_signal);
    signal(SIGHUP, watch_signal);
    atexit(automation_off_on_exit);

    BatteryInfo info;
    bool have_info = battery_get_info(&info);
    bool last_ac = have_info && info.acAttached;
    bool previous_hold = have_info && automation_hold_active(&info);
    bool hold_before_unplug = false;
    bool last_display = automation_external_display_connected();
    bool auto_lpm_owned = false;
    bool warned_master = false;
    bool warned_caffeine = false;
    bool warned_lpm = false;
    time_t last_lpm_attempt = 0;

    watch_print_settings(options);

    if (prefs_get_bool(BYP_KEY_AUTO_HOLD_AT_LOGIN, false)) {
        watch_engage("login", options, &warned_master);
    }
    if (prefs_get_bool(BYP_KEY_AUTO_HOLD_ON_PLUG, false) && last_ac) {
        watch_engage("plug", options, &warned_master);
    }
    if (prefs_get_bool(BYP_KEY_AUTO_HOLD_ON_DISPLAY, true) && last_display) {
        watch_engage("display", options, &warned_master);
    }

    while (g_watch_running) {
        if (!battery_get_info(&info)) {
            for (int i = 0; i < WATCH_TICKS && g_watch_running; i++) usleep(WATCH_TICK_MS * 1000);
            continue;
        }
        bool ac = info.acAttached;
        bool hold = automation_hold_active(&info);
        bool display = automation_external_display_connected();

        if (ac && !last_ac) {
            bool wanted = prefs_get_bool(BYP_KEY_AUTO_HOLD_ON_PLUG, false) ||
                          hold_before_unplug ||
                          access("/tmp/byp.state", F_OK) == 0;
            hold_before_unplug = false;
            if (wanted) watch_engage("plug", options, &warned_master);
        } else if (!ac && last_ac) {
            hold_before_unplug = previous_hold;
        }
        if (display && !last_display) {
            if (prefs_get_bool(BYP_KEY_AUTO_HOLD_ON_DISPLAY, true)) {
                watch_engage("display", options, &warned_master);
            }
        }

        // The app's master slider is the one control that turns everything
        // off. While it is down the runner keeps polling but drives nothing,
        // so it cannot re-enable what the slider disabled.
        bool master = master_enabled();
        if (!master && !warned_master) {
            fprintf(stderr, "master slider is down, automations are held off\n");
            warned_master = true;
        } else if (master) {
            warned_master = false;
        }

        if (master) {
            // Caffeinate: the switch, or any armed condition whose trigger
            // holds right now.
            bool want_caffeine = automation_caffeinate_wanted(&info);
            bool caffeine_running = automation_caffeinate_running();
            if (want_caffeine && !caffeine_running) {
                if (automation_caffeinate_start()) {
                    watch_log(options, "caffeinate: on");
                } else if (!warned_caffeine) {
                    fprintf(stderr, "caffeinate: could not start /usr/bin/caffeinate\n");
                    warned_caffeine = true;
                }
            } else if (!want_caffeine && caffeine_running) {
                if (automation_caffeinate_stop()) watch_log(options, "caffeinate: off");
            }

            // Per-app auto Low Power Mode. Only a Low Power Mode this process
            // turned on is turned back off, so a manual `byper lpm on` survives.
            char *bundle = automation_frontmost_bundle_id();
            bool listed = bundle && prefs_string_array_contains(BYP_KEY_AUTO_LPM_BUNDLE_IDS, bundle);
            time_t now = time(NULL);
            if (listed) {
                if (!automation_low_power_mode() && now - last_lpm_attempt >= LPM_RETRY_SECONDS) {
                    last_lpm_attempt = now;
                    if (automation_set_low_power_mode(true)) {
                        if (!auto_lpm_owned) {
                            auto_lpm_owned = true;
                            char message[256];
                            snprintf(message, sizeof(message), "lpm: on (%s)", bundle);
                            watch_log(options, message);
                        }
                    } else if (!warned_lpm) {
                        fprintf(stderr, "lpm: pmset refused, Low Power Mode needs root\n");
                        warned_lpm = true;
                    }
                }
            } else if (auto_lpm_owned) {
                if (automation_set_low_power_mode(false)) {
                    auto_lpm_owned = false;
                    watch_log(options, "lpm: off");
                }
            }
            free(bundle);
        } else if (auto_lpm_owned) {
            if (automation_set_low_power_mode(false)) {
                auto_lpm_owned = false;
                watch_log(options, "lpm: off");
            }
        }

        last_ac = ac;
        previous_hold = hold;
        last_display = display;
        for (int i = 0; i < WATCH_TICKS && g_watch_running; i++) usleep(WATCH_TICK_MS * 1000);
    }

    if (auto_lpm_owned) {
        automation_set_low_power_mode(false);
        watch_log(options, "lpm: off");
    }
    if (!prefs_get_bool(BYP_KEY_CAFFEINE_ALWAYS_ON, false)) {
        automation_caffeinate_stop();
    }
    unlink(pid_path);
    close(lock_fd);
    if (!options->quiet) {
        printf("stopped\n");
        fflush(stdout);
    }
    return 0;
}
