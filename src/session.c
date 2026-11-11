#include "session.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#include "automation.h"
#include "battery.h"
#include "prefs.h"

struct SessionLog {
    FILE *file;
    char path[1024];
    char name[256];
    time_t started;
    int samples;
};

static void session_read_sysctl(const char *name, char *out, size_t size, const char *fallback) {
    size_t length = size;
    if (sysctlbyname(name, out, &length, NULL, 0) != 0 || length == 0) {
        snprintf(out, size, "%s", fallback);
    }
}

// The Desktop of the user whose settings we share. A SUID run must not write
// into root's home, so the directory comes from the resolved settings owner.
static void session_directory(char *out, size_t size) {
    const char *home = prefs_user_home();
    struct stat info;
    snprintf(out, size, "%s/Desktop", home);
    if (stat(out, &info) == 0 && S_ISDIR(info.st_mode)) return;
    if (home[0] && strcmp(home, "/") != 0) {
        snprintf(out, size, "%s", home);
        if (stat(out, &info) == 0 && S_ISDIR(info.st_mode)) return;
    }
    snprintf(out, size, "/tmp");
}

static void session_write_header(SessionLog *log) {
    char stamp[64];
    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &parts);

    char model[128];
    char cpu[256];
    char os_version[64];
    char os_build[64];
    session_read_sysctl("hw.model", model, sizeof(model), "Mac");
    session_read_sysctl("machdep.cpu.brand_string", cpu, sizeof(cpu), "Apple Silicon");
    session_read_sysctl("kern.osproductversion", os_version, sizeof(os_version), "unknown");
    session_read_sysctl("kern.osversion", os_build, sizeof(os_build), "unknown");

    long cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (cores < 1) cores = 1;

    BatteryInfo info;
    memset(&info, 0, sizeof(info));
    battery_get_info(&info);

    char adapter[160];
    if (info.acAttached) {
        snprintf(adapter, sizeof(adapter), "%s (%d W)",
                 info.adapterDesc[0] ? info.adapterDesc : "AC Connected", info.adapterWatts);
    } else {
        snprintf(adapter, sizeof(adapter), "Unplugged (On Battery)");
    }

    fprintf(log->file, "BYPER POWER & BATTERY LOG,,,,,,\n");
    fprintf(log->file, "Timestamp: %s,,,,,,\n", stamp);
    fprintf(log->file, "Mac Model: %s (%ld CPU Cores),,,,,,\n", model, cores);
    fprintf(log->file, "Processor: %s,,,,,,\n", cpu);
    fprintf(log->file, "Operating Sys: macOS %s (Build %s),,,,,,\n", os_version, os_build);
    fprintf(log->file, "Battery Info: %d Charge Cycles,,,,,,\n", info.cycleCount);
    fprintf(log->file, "Power Adapter: %s,,,,,,\n", adapter);
    fprintf(log->file, ",,,,,,\n");
    fprintf(log->file, ",\n");
    fprintf(log->file, "Time,Elapsed,Batt %%,Power State,Current (mA),Power (W),Voltage (V),"
                       "Temp (\xC2\xB0" "C),NCR (hex),NCR Description,Cycles,Adapter (W),LPM,"
                       "Caffeinate,Battery Chip,Pack mV\n");
    fflush(log->file);
}

SessionLog *session_log_start(void) {
    SessionLog *log = (SessionLog *)calloc(1, sizeof(SessionLog));
    if (!log) return NULL;

    char directory[768];
    session_directory(directory, sizeof(directory));

    char stamp[32];
    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);
    strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", &parts);

    snprintf(log->name, sizeof(log->name), "byper-session-%s.csv", stamp);
    snprintf(log->path, sizeof(log->path), "%s/%s", directory, log->name);

    int fd = open(log->path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0644);
    if (fd < 0) {
        free(log);
        return NULL;
    }
    if (geteuid() == 0) {
        (void)fchown(fd, prefs_user_uid(), prefs_user_gid());
    }
    log->file = fdopen(fd, "w");
    if (!log->file) {
        close(fd);
        unlink(log->path);
        free(log);
        return NULL;
    }
    log->started = now;
    session_write_header(log);
    return log;
}

void session_log_sample(SessionLog *log) {
    if (!log || !log->file) return;
    BatteryInfo info;
    if (!battery_get_info(&info)) return;

    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);
    char clock[16];
    strftime(clock, sizeof(clock), "%H:%M:%S", &parts);

    long elapsed = (long)(now - log->started);
    if (elapsed < 0) elapsed = 0;

    const char *state;
    if (!info.acAttached) {
        state = "On Battery";
    } else if (automation_hold_active(&info)) {
        state = "Bypass (Hold)";
    } else if (info.isCharging) {
        state = "Fast Charging";
    } else {
        state = "AC Attached";
    }

    char adapter[32];
    if (info.adapterWatts > 0) snprintf(adapter, sizeof(adapter), "%d W", info.adapterWatts);
    else snprintf(adapter, sizeof(adapter), "-");

    fprintf(log->file, "%s,+%02ld:%02ld:%02ld,%d%%,%s,%d,%.2f W,%.3f V,%.2f\xC2\xB0" "C,0x%08X,%s,%d,%s,%s,%s,%s,%d\n",
            clock, elapsed / 3600, (elapsed / 60) % 60, elapsed % 60,
            info.percentage, state, info.amperage,
            fabs(info.wattage), (double)info.voltage / 1000.0, info.temperature,
            info.notChargingReason, battery_get_not_charging_reason_desc(info.notChargingReason),
            info.cycleCount, adapter,
            automation_low_power_mode() ? "On" : "Off",
            automation_caffeinate_running() ? "On" : "Off",
            info.deviceName[0] ? info.deviceName : "-",
            info.voltage);
    fflush(log->file);
    log->samples++;
}

void session_log_stop(SessionLog *log) {
    if (!log) return;
    if (log->file) {
        fprintf(log->file, ",,,,,,\n");
        fprintf(log->file, "SUMMARY: %d samples recorded | Log File: %s\n", log->samples, log->name);
        fclose(log->file);
        log->file = NULL;
    }
    // The struct stays allocated: the caller reads the path and the sample
    // count after stopping, and the process is about to exit.
}

const char *session_log_path(const SessionLog *log) {
    return log ? log->path : "";
}

int session_log_samples(const SessionLog *log) {
    return log ? log->samples : 0;
}
