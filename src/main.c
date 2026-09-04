#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <math.h>
#include <sys/time.h>
#include <sys/select.h>
#include <termios.h>
#include <pthread.h>
#include <pwd.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include "smc.h"
#include "battery.h"
#include "power.h"
#include "powerui.h"

#define VERSION "3.5.0"

// ANSI Formatting (3-Color keyword map: Green, Cyan, Yellow; Dim structure, Bright values)
#define CLR_RESET   "\033[0m"
#define CLR_BRIGHT  "\033[1m"
#define CLR_DIM     "\033[2m"
#define CLR_GREEN   "\033[32m"
#define CLR_CYAN    "\033[36m"
#define CLR_YELLOW  "\033[33m"

static char *g_session_log = NULL;
static size_t g_session_log_len = 0;
static size_t g_session_log_cap = 0;

static struct termios g_orig_termios;
static bool g_termios_set = false;
static volatile bool g_live_running = true;

static void session_log_append(const char *str) {
    if (!str) return;
    size_t slen = strlen(str);
    if (g_session_log_len + slen + 1 > g_session_log_cap) {
        size_t new_cap = (g_session_log_cap == 0) ? 65536 : g_session_log_cap * 2;
        while (g_session_log_len + slen + 1 > new_cap) {
            new_cap *= 2;
        }
        char *new_buf = (char *)realloc(g_session_log, new_cap);
        if (!new_buf) return;
        g_session_log = new_buf;
        g_session_log_cap = new_cap;
    }
    memcpy(g_session_log + g_session_log_len, str, slen);
    g_session_log_len += slen;
    g_session_log[g_session_log_len] = '\0';
}

static double g_accum_wall_wh = 0.0;
static double g_accum_battery_wh = 0.0;
static double g_accum_system_wh = 0.0;
static struct timeval g_last_wh_sample = {0, 0};

static void update_wh_counters(double wall_w, double batt_w, double load_w) {
    struct timeval tv_now;
    gettimeofday(&tv_now, NULL);
    if (g_last_wh_sample.tv_sec != 0) {
        double dt_sec = (tv_now.tv_sec - g_last_wh_sample.tv_sec) + (tv_now.tv_usec - g_last_wh_sample.tv_usec) / 1000000.0;
        if (dt_sec > 0.0 && dt_sec < 60.0) {
            double dt_hours = dt_sec / 3600.0;
            g_accum_wall_wh += wall_w * dt_hours;
            g_accum_battery_wh += batt_w * dt_hours;
            g_accum_system_wh  += load_w * dt_hours;
        }
    }
    g_last_wh_sample = tv_now;
}

static int get_adapter_watts(void) {
    return battery_get_adapter_watts();
}

static void log_session_header_if_needed(void) {
    if (g_session_log_len > 0) return;

    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    char timestr[64];
    strftime(timestr, sizeof(timestr), "%Y-%m-%d %H:%M:%S", tm_info);

    char os_ver[64] = {0};
    char os_prod[64] = {0};
    char model[64] = {0};
    size_t sz = sizeof(os_ver);
    sysctlbyname("kern.osversion", os_ver, &sz, NULL, 0);
    sz = sizeof(os_prod);
    sysctlbyname("kern.osproductversion", os_prod, &sz, NULL, 0);
    sz = sizeof(model);
    sysctlbyname("hw.model", model, &sz, NULL, 0);

    BatteryInfo bInfo;
    memset(&bInfo, 0, sizeof(bInfo));
    battery_get_info(&bInfo);

    int ad_w = get_adapter_watts();
    const char *ad_desc = (bInfo.acAttached ? (ad_w > 0 ? "USB-PD / MagSafe Charger" : "AC Connected") : "Unplugged (Battery Power)");

    double health_pct = (bInfo.designCapacity > 0 && bInfo.fullChargeCapacity > 0) ?
        ((double)bInfo.fullChargeCapacity / (double)bInfo.designCapacity * 100.0) : 100.0;

    char header[2048];
    int hlen = snprintf(header, sizeof(header),
        "================================================================================\n"
        "                         BYPER POWER & BATTERY LOG\n"
        "================================================================================\n"
        "Timestamp:      %s\n"
        "Mac Model:      %s (Apple Silicon)\n"
        "Operating Sys:  macOS %s (Build %s)\n"
        "Battery Health: %d Charge Cycles | Maximum Capacity: %.1f%%\n"
        "Power Adapter:  %s (%dW)\n"
        "================================================================================\n\n"
        "Time      Elapsed   Batt   Power State           Current Flow      Power Draw   Temp\n"
        "--------------------------------------------------------------------------------\n",
        timestr, model, os_prod, os_ver,
        bInfo.cycleCount, health_pct,
        ad_desc, ad_w
    );
    if (hlen > 0) {
        session_log_append(header);
    }
}

static void log_step_record(const char *action, const char *result) {
    (void)action;
    (void)result;
    log_session_header_if_needed();

    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    char timestr[32];
    strftime(timestr, sizeof(timestr), "%H:%M:%S", tm_info);

    BatteryInfo bInfo;
    memset(&bInfo, 0, sizeof(bInfo));
    battery_get_info(&bInfo);

    PowerBreakdown pb;
    power_sample_breakdown(&pb);

    double wall_w = pb.ac_connected ? pb.dc_in_w : 0.0;
    if (pb.ac_connected && wall_w <= 0.0f) {
        int ad_w = get_adapter_watts();
        if (ad_w > 0) wall_w = (double)ad_w;
    }
    update_wh_counters(wall_w, pb.battery_w, pb.total_system_w);

    bool isHold = (bInfo.acAttached && !bInfo.isCharging && ((bInfo.notChargingReason & 0x01000000) != 0) && abs(bInfo.amperage) < 100);
    const char *state_str = !bInfo.acAttached ? "On Battery" : (isHold ? "Bypass (Hold)" : (bInfo.isCharging ? "Fast Charging" : "AC Full (100%)"));

    char flow_str[32];
    if (isHold || abs(bInfo.amperage) < 50) {
        snprintf(flow_str, sizeof(flow_str), "0 mA (Resting)");
    } else {
        snprintf(flow_str, sizeof(flow_str), "%+d mA", bInfo.amperage);
    }

    char power_str[32];
    snprintf(power_str, sizeof(power_str), "%.1f W", fabs(bInfo.wattage));

    char batt_str[16];
    snprintf(batt_str, sizeof(batt_str), "%d%%", bInfo.percentage);

    char record[512];
    int rlen = snprintf(record, sizeof(record),
        "%-8s  +00:00    %-5s  %-20s  %-16s  %-11s  %.1f°C\n",
        timestr, batt_str, state_str, flow_str, power_str, bInfo.temperature
    );

    if (rlen > 0) {
        session_log_append(record);
    }
}

static void print_status(bool json_output) {
    BatteryInfo info;
    if (!battery_get_info(&info)) {
        if (json_output) printf("{}\n");
        else printf("[FAIL] registers unreadable\n");
        exit(3);
    }

    NativeHoldStatus nhs;
    powerui_get_status(&nhs);

    bool isHold = (info.acAttached && !info.isCharging && ((info.notChargingReason & 0x01000000) != 0) && abs(info.amperage) < 100);

    if (json_output) {
        printf("{\n");
        printf("  \"percentage\": %d,\n", info.percentage);
        printf("  \"acAttached\": %s,\n", info.acAttached ? "true" : "false");
        printf("  \"isCharging\": %s,\n", info.isCharging ? "true" : "false");
        printf("  \"holdActive\": %s,\n", isHold ? "true" : "false");
        printf("  \"inMemoryHoldActive\": %s,\n", isHold ? "true" : "false");
        printf("  \"chargeLimit\": %d,\n", nhs.currentLimit);
        printf("  \"amperage_mA\": %d,\n", info.amperage);
        printf("  \"voltage_mV\": %d,\n", info.voltage);
        printf("  \"wattage_W\": %.2f,\n", info.wattage);
        printf("  \"cycleCount\": %d,\n", info.cycleCount);
        printf("  \"temperature_C\": %.1f,\n", info.temperature);
        printf("  \"adapterWatts\": %d,\n", info.adapterWatts);
        printf("  \"adapterVoltage_mV\": %d,\n", info.adapterVoltage_mV);
        printf("  \"adapterCurrent_mA\": %d,\n", info.adapterCurrent_mA);
        printf("  \"adapterSelectedPdo\": %d,\n", info.adapterSelectedPdo);
        printf("  \"adapterPdoCount\": %d,\n", info.adapterPdoCount);
        printf("  \"adapterDesc\": \"%s\",\n", info.adapterDesc);
        printf("  \"pmuConfigured\": %d,\n", info.pmuConfigured);
        printf("  \"notChargingReason\": %u,\n", info.notChargingReason);
        printf("  \"notChargingReasonDesc\": \"%s\",\n", battery_get_not_charging_reason_desc(info.notChargingReason));
        printf("  \"serial\": \"%s\",\n", info.serial);
        printf("  \"deviceName\": \"%s\"\n", info.deviceName);
        printf("}\n");
    }
}

static void print_status_quick(void) {
    BatteryInfo info;
    if (!battery_get_info(&info)) {
        printf("[FAIL] registers unreadable\n");
        exit(3);
    }
    bool isHold = (info.acAttached && !info.isCharging && ((info.notChargingReason & 0x01000000) != 0) && abs(info.amperage) < 100);
    const char *state_word = !info.acAttached ? "on battery" : (isHold ? "hold" : (info.isCharging ? "charging" : "idle"));
    printf("batt: %d%% | state: %s | flow: %+d mA (%.1f W) | temp: %.1f °C | pmu: %d | ncr: 0x%08x\n",
           info.percentage, state_word, info.amperage, info.wattage, info.temperature, info.pmuConfigured, info.notChargingReason);
}

static void print_power_breakdown(void) {
    BatteryInfo info;
    PowerBreakdown pb;
    if (!battery_get_info(&info) || !power_sample_breakdown(&pb)) {
        printf("[FAIL] registers unreadable\n");
        exit(3);
    }

    const char *state_word = !info.acAttached ? "on battery" : (pb.is_hold ? "hold" : (info.isCharging ? "charging" : "idle"));
    printf("state: %s | batt: %d%% | temp: %.1f °C | ncr: 0x%08x\n",
           state_word, info.percentage, info.temperature, info.notChargingReason);

    if (info.acAttached) {
        printf("wall:  %.1f W dc-in (PDTR) | adapter: %s (%d W, %+d mA @ %d mV)\n",
               pb.dc_in_w, info.adapterDesc[0] ? info.adapterDesc : "unknown",
               info.adapterWatts, info.adapterCurrent_mA, info.adapterVoltage_mV);
        printf("load:  %.1f W net system (wall - battery)\n", pb.total_system_w);
    } else {
        printf("wall:  unplugged\n");
        printf("load:  %.1f W from battery\n", pb.total_system_w);
    }

    printf("rails: soc %.2f W (PDBR) | dram %.2f W (PMVR) | pmic %.2f W (PMVC) | ppmc %.2f W (PPMC) | sum %.2f W\n",
           pb.soc_w, pb.dram_w, pb.pmic_w, pb.pkg_w,
           (double)(pb.soc_w + pb.dram_w + pb.pmic_w + pb.pkg_w));

    printf("batt:  %+d mA @ %d mV (%+.1f W) | cells %u/%u/%u mV\n",
           pb.battery_ma, pb.battery_mv, pb.battery_w,
           pb.cell1_mv, pb.cell2_mv, pb.cell3_mv);
}

static bool engage_bypass_at_any_percentage(void) {
    bool ok = powerui_enable_hold();
    if (ok) {
        FILE *fp = fopen("/tmp/byp.state", "w");
        if (fp) {
            fprintf(fp, "active\n");
            fclose(fp);
        }
    } else {
        unlink("/tmp/byp.state");
    }
    return ok;
}

static bool disable_bypass_and_resume_charging(void) {
    unlink("/tmp/byp.state");
    bool ok = powerui_disable_hold();
    return ok;
}

typedef struct {
    volatile bool stop;
    volatile int stage; // 0="reading registers", 1="verifying state", 2="waiting for settle"
} DotMeshCtx;

static void* dot_mesh_thread_func(void *arg) {
    DotMeshCtx *ctx = (DotMeshCtx *)arg;
    int pos = 0;
    int tick = 0;
    const int num_dots = 12;
    const char *labels[] = { "reading registers", "verifying state", "waiting for settle" };

    while (!ctx->stop) {
        int label_idx = ctx->stage;
        if (label_idx < 0 || label_idx > 2) label_idx = (tick / 8) % 3;

        printf("\r  ");
        for (int i = 0; i < num_dots; i++) {
            if (i == pos) {
                printf(CLR_BRIGHT "*" CLR_RESET " ");
            } else {
                printf(CLR_DIM "." CLR_RESET " ");
            }
        }
        printf(CLR_DIM " %s" CLR_RESET "\033[K", labels[label_idx]);
        fflush(stdout);

        pos++;
        if (pos >= num_dots) {
            pos = 0;
        }

        tick++;
        usleep(60000); // 60ms
    }
    printf("\r\033[K");
    fflush(stdout);
    return NULL;
}

static void run_calibration_sweep(void) {
    if (!isatty(STDOUT_FILENO)) return;
    const int num_dots = 12;
    const char *labels[] = { "reading registers", "verifying state", "waiting for settle" };
    for (int tick = 0; tick < num_dots; tick++) {
        int label_idx = (tick / 4) % 3;
        printf("\r  ");
        for (int i = 0; i < num_dots; i++) {
            if (i == tick) {
                printf(CLR_BRIGHT "*" CLR_RESET " ");
            } else {
                printf(CLR_DIM "." CLR_RESET " ");
            }
        }
        printf(CLR_DIM " %s" CLR_RESET "\033[K", labels[label_idx]);
        fflush(stdout);
        usleep(25000); // 25ms
    }
    printf("\r\033[K");
    fflush(stdout);
}

static void disable_raw_mode(void) {
    if (g_termios_set) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_orig_termios);
        printf("\033[?25h"); // show cursor
        fflush(stdout);
        g_termios_set = false;
    }
}

static void enable_raw_mode(void) {
    if (!isatty(STDIN_FILENO)) return;
    if (tcgetattr(STDIN_FILENO, &g_orig_termios) == 0) {
        g_termios_set = true;
        atexit(disable_raw_mode);
        struct termios raw = g_orig_termios;
        raw.c_lflag &= ~(ECHO | ICANON);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 0;
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
        printf("\033[?25l"); // hide cursor
        fflush(stdout);
    }
}

static void handle_live_sig(int sig) {
    (void)sig;
    g_live_running = false;
}

static int export_session_log(char *out_path, size_t out_path_size) {
    const char *home = getenv("HOME");
    const char *sudo_user = getenv("SUDO_USER");
    if (!sudo_user) sudo_user = getenv("USER");
    if (!sudo_user) sudo_user = getenv("LOGNAME");

    char user_home[256] = {0};
    if (sudo_user && strcmp(sudo_user, "root") != 0) {
        struct passwd *pw = getpwnam(sudo_user);
        if (pw && pw->pw_dir) {
            strncpy(user_home, pw->pw_dir, sizeof(user_home) - 1);
            home = user_home;
        }
    }

    if (!home || strcmp(home, "/var/root") == 0 || strcmp(home, "/private/var/root") == 0) {
        struct stat st;
        if (stat("/Users/gefaass/Desktop", &st) == 0) {
            home = "/Users/gefaass";
        } else {
            home = "/tmp";
        }
    }

    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    char timestr[64];
    strftime(timestr, sizeof(timestr), "%Y%m%d-%H%M%S", tm_info);

    snprintf(out_path, out_path_size, "%s/Desktop/byper-session-%s.txt", home, timestr);

    if (g_session_log_len == 0) {
        log_step_record("export", "session snapshot");
    }

    FILE *fp = fopen(out_path, "w");
    if (!fp) return -1;

    fwrite(g_session_log, 1, g_session_log_len, fp);
    fclose(fp);

    if (sudo_user) {
        struct passwd *pw = getpwnam(sudo_user);
        if (pw) {
            chown(out_path, pw->pw_uid, pw->pw_gid);
        }
    }

    int line_count = 0;
    for (size_t i = 0; i < g_session_log_len; i++) {
        if (g_session_log[i] == '\n') line_count++;
    }
    if (g_session_log_len > 0 && g_session_log[g_session_log_len - 1] != '\n') line_count++;
    return line_count;
}

typedef struct {
    bool active;
    char key;
    int target_state;           // 1=hold, 2=charging
    double start_time;
    int spinner_tick;
    bool completed;
    bool success;
    double elapsed_sec;
    time_t display_until;
    pthread_t thread;
    bool thread_active;
} PendingAction;

typedef struct {
    int target_state;
    volatile bool finished;
    volatile bool result;
} ActionWorkerArgs;

static ActionWorkerArgs g_action_worker_args;

static void* action_worker_thread(void *arg) {
    ActionWorkerArgs *args = (ActionWorkerArgs *)arg;
    if (args->target_state == 2) {
        args->result = disable_bypass_and_resume_charging();
    } else {
        args->result = engage_bypass_at_any_percentage();
    }
    args->finished = true;
    return NULL;
}

static void format_flow_glyphs(char *out, size_t out_sz, bool active, bool is_valve_closed, const char *state_clr, int frame_idx) {
    if (!active) {
        if (is_valve_closed) {
            snprintf(out, out_sz, CLR_DIM "✕" CLR_RESET " " CLR_DIM "✕" CLR_RESET " " CLR_DIM "✕" CLR_RESET);
        } else {
            snprintf(out, out_sz, CLR_DIM "▶" CLR_RESET " " CLR_DIM "▶" CLR_RESET " " CLR_DIM "▶" CLR_RESET);
        }
        return;
    }

    int frame = frame_idx % 3;
    if (frame == 0) {
        // Frame 1: [BRIGHT]▶[/BRIGHT] [DIM]▶[/DIM] [DIM]▶[/DIM]
        snprintf(out, out_sz, "%s" CLR_BRIGHT "▶" CLR_RESET " " CLR_DIM "▶" CLR_RESET " " CLR_DIM "▶" CLR_RESET, state_clr);
    } else if (frame == 1) {
        // Frame 2: [DIM]▶[/DIM] [BRIGHT]▶[/BRIGHT] [DIM]▶[/DIM]
        snprintf(out, out_sz, CLR_DIM "▶" CLR_RESET " %s" CLR_BRIGHT "▶" CLR_RESET " " CLR_DIM "▶" CLR_RESET, state_clr);
    } else {
        // Frame 3: [DIM]▶[/DIM] [DIM]▶[/DIM] [BRIGHT]▶[/BRIGHT]
        snprintf(out, out_sz, CLR_DIM "▶" CLR_RESET " " CLR_DIM "▶" CLR_RESET " %s" CLR_BRIGHT "▶" CLR_RESET, state_clr);
    }
}

static void live_view_run(void) {
    g_live_running = true;
    signal(SIGINT, handle_live_sig);
    signal(SIGTERM, handle_live_sig);

    bool is_tty = isatty(STDOUT_FILENO);

    // State tracking for time-in-state, settling tildes, and cross-check band
    int last_state = 0; // 1=hold, 2=charging, 3=on battery
    int time_in_state_cur = -1;
    time_t state_start_time = 0;

    int settle_state = -1;
    bool settle_ac = false;
    time_t settle_start_time = 0;
    bool is_settling = false;
    double settle_prev_batt_w = -999.0;
    double settle_prev_load_w = -999.0;
    int settle_agree_count = 0;

    int cross_check_disagree_count = 0;

    // Launch Reconciliation: If /tmp/byp.state says hold but registers show AC attached with battery discharging,
    // treat it as plug cycle residue: run resume path, record action=plug_cycle, and show charging frame.
    bool state_file_hold = (access("/tmp/byp.state", F_OK) == 0);
    PowerBreakdown init_pb;
    BatteryInfo init_bi;
    if (power_sample_breakdown(&init_pb) && battery_get_info(&init_bi)) {
        bool discharging = (init_pb.battery_ma <= -50 || init_bi.amperage <= -50);
        if (init_pb.ac_connected) {
            if (discharging || (state_file_hold && !init_pb.is_hold && init_bi.amperage < 0)) {
                disable_bypass_and_resume_charging();
                log_step_record("plug_cycle", "defaulted to charging");
            } else if (state_file_hold && !init_pb.is_hold && init_pb.is_charging) {
                unlink("/tmp/byp.state");
            }
        }
    }

    bool prev_ac_connected = true;
    bool hold_active_prior = (access("/tmp/byp.state", F_OK) == 0);
    PowerBreakdown init_check;
    if (power_sample_breakdown(&init_check)) {
        prev_ac_connected = init_check.ac_connected;
        if (init_check.ac_connected && init_check.is_hold) {
            hold_active_prior = true;
        }
    }

    if (!is_tty) {
        while (g_live_running) {
            time_t now = time(NULL);
            struct tm *tm_info = localtime(&now);
            char time_str[32];
            strftime(time_str, sizeof(time_str), "%H:%M:%S", tm_info);

            PowerBreakdown pb;
            if (!power_sample_breakdown(&pb)) {
                printf("[%s] [FAIL] registers unreadable\n", time_str);
                fflush(stdout);
                sleep(1);
                continue;
            }

            BatteryInfo bInfo;
            battery_get_info(&bInfo);

            bool isHold = (pb.ac_connected && !pb.is_charging && ((pb.not_charging_reason & 0x01000000) != 0) && abs(pb.battery_ma) < 100);
            if (pb.ac_connected && isHold) {
                hold_active_prior = true;
            } else if (pb.ac_connected && (pb.is_charging || pb.battery_ma >= 50)) {
                hold_active_prior = false;
            }

            // ADDENDUM 4: Plug cycle detection & Live reconciliation for non-TTY
            if (!prev_ac_connected && pb.ac_connected) {
                if (hold_active_prior || access("/tmp/byp.state", F_OK) == 0) {
                    disable_bypass_and_resume_charging();
                    log_step_record("plug_cycle", "defaulted to charging");
                    hold_active_prior = false;
                    power_sample_breakdown(&pb);
                    battery_get_info(&bInfo);
                    isHold = (pb.ac_connected && !pb.is_charging && ((pb.not_charging_reason & 0x01000000) != 0) && abs(pb.battery_ma) < 100);
                }
            } else if (pb.ac_connected && (pb.battery_ma <= -50 || bInfo.amperage <= -50)) {
                disable_bypass_and_resume_charging();
                log_step_record("plug_cycle", "defaulted to charging");
                hold_active_prior = false;
                power_sample_breakdown(&pb);
                battery_get_info(&bInfo);
                isHold = (pb.ac_connected && !pb.is_charging && ((pb.not_charging_reason & 0x01000000) != 0) && abs(pb.battery_ma) < 100);
            }
            prev_ac_connected = pb.ac_connected;

            int ad_w = get_adapter_watts();
            const char *batt_word = !pb.ac_connected ? "discharging" : (isHold ? "resting" : "charging");

            int cur_state = !pb.ac_connected ? 3 : (isHold ? 1 : 2);
            if (time_in_state_cur != cur_state) {
                time_in_state_cur = cur_state;
                state_start_time = now;
            }
            long state_elapsed = (long)(now - state_start_time);
            int state_m = (int)(state_elapsed / 60);
            int state_s = (int)(state_elapsed % 60);

            int pct = pb.percentage;
            if (pct < 0) pct = 0; if (pct > 100) pct = 100;
            int filled = pct / 10;
            if (filled < 0) filled = 0; if (filled > 10) filled = 10;
            char bar[64] = {0};
            char *pbar = bar;
            for (int i = 0; i < filled; i++) pbar += sprintf(pbar, "█");
            for (int i = filled; i < 10; i++) pbar += sprintf(pbar, "░");

            char est_line[128] = {0};
            if (!pb.ac_connected) {
                double dischg_w = pb.total_system_w > 0.1 ? pb.total_system_w : fabs(pb.battery_w);
                if (dischg_w < 0.1) dischg_w = 0.1;
                int mins = 0;
                if (bInfo.avgTimeToEmpty > 0 && bInfo.avgTimeToEmpty < 65535) {
                    mins = bInfo.avgTimeToEmpty;
                } else {
                    int cur_cap = bInfo.remainingCapacity > 0 ? bInfo.remainingCapacity : (bInfo.percentage * 50);
                    double rem_wh = ((double)cur_cap * (double)pb.battery_mv) / 1000000.0;
                    mins = (int)((rem_wh / dischg_w) * 60.0 + 0.5);
                }
                if (mins < 1) mins = 1;
                if (mins >= 60) snprintf(est_line, sizeof(est_line), "~%dh %02dm left at %.1f W", mins / 60, mins % 60, dischg_w);
                else snprintf(est_line, sizeof(est_line), "~%dm left at %.1f W", mins, dischg_w);
            } else if (isHold || abs(pb.battery_ma) < 50) {
                snprintf(est_line, sizeof(est_line), "resting");
            } else {
                int full_cap = bInfo.fullChargeCapacity > 0 ? bInfo.fullChargeCapacity : (bInfo.designCapacity > 0 ? bInfo.designCapacity : 5292);
                int cur_cap = bInfo.remainingCapacity > 0 ? bInfo.remainingCapacity : (bInfo.percentage * full_cap / 100);
                int rem_mah = full_cap - cur_cap;
                if (rem_mah < 0) rem_mah = 0;
                double cur_a = (double)pb.battery_ma / 1000.0;
                if (cur_a < 0.05) cur_a = 0.05;
                int mins = (int)((rem_mah / (cur_a * 1000.0)) * 60.0 + 0.5);
                if (mins < 1) mins = 1;
                if (mins >= 60) snprintf(est_line, sizeof(est_line), "full in ~%dh %02dm at %.1f A", mins / 60, mins % 60, cur_a);
                else snprintf(est_line, sizeof(est_line), "full in ~%dm at %.1f A", mins, cur_a);
            }

            char time_in_state_str[32];
            if (state_m > 0) {
                snprintf(time_in_state_str, sizeof(time_in_state_str), "(%dm %02ds)", state_m, state_s);
            } else {
                snprintf(time_in_state_str, sizeof(time_in_state_str), "(%ds)", state_s);
            }

            const char *wall_laptop_flow = (pb.total_system_w > 0.1) ? ">>>" : "---";
            bool batt_active = (fabs(pb.battery_w) > 0.1 && !isHold && abs(pb.battery_ma) >= 50);
            const char *wall_batt_flow = batt_active ? ">>>" : "---";

            if (pb.ac_connected) {
                if (isHold || abs(pb.battery_ma) < 50) {
                    printf("[%s] WALL %s laptop: %.1f W | WALL %s battery: %.1f W (%+d mA) | bar: [%s] %d%% %s %s | adapter: %d W\n",
                           time_str, wall_laptop_flow, pb.total_system_w,
                           wall_batt_flow, fabs(pb.battery_w), pb.battery_ma,
                           bar, pct, batt_word, time_in_state_str, ad_w > 0 ? ad_w : (int)(pb.dc_in_w + 0.5f));
                } else {
                    printf("[%s] WALL %s laptop: %.1f W | WALL %s battery: %.1f W (%+d mA) | bar: [%s] %d%% %s %s | %s | adapter: %d W\n",
                           time_str, wall_laptop_flow, pb.total_system_w,
                           wall_batt_flow, fabs(pb.battery_w), pb.battery_ma,
                           bar, pct, batt_word, time_in_state_str, est_line, ad_w > 0 ? ad_w : (int)(pb.dc_in_w + 0.5f));
                }
            } else {
                bool batt_discharging_active = (pb.total_system_w > 0.1 || fabs(pb.battery_w) > 0.1);
                const char *batt_laptop_flow = batt_discharging_active ? ">>>" : "---";
                printf("[%s] wall: --- unplugged | BATT %s laptop: %.1f W (%+d mA) | bar: [%s] %d%% discharging %s | %s\n",
                       time_str, batt_laptop_flow, pb.total_system_w, pb.battery_ma, bar, pct, time_in_state_str, est_line);
            }
            fflush(stdout);
            sleep(1);
        }
        return;
    }

    enable_raw_mode();

    time_t start_time = time(NULL);
    int tick = 0;
    bool show_raw = false;
    char transient_msg[256] = {0};
    time_t transient_until = 0;
    PendingAction pending_act;
    memset(&pending_act, 0, sizeof(pending_act));

    while (g_live_running) {
        time_t now = time(NULL);
        long elapsed = (long)(now - start_time);
        char spinner_chars[4] = {'|', '/', '-', '\\'};
        char spinner = spinner_chars[tick % 4];

        struct tm *tm_info = localtime(&now);
        char time_str[32];
        strftime(time_str, sizeof(time_str), "%H:%M:%S", tm_info);

        PowerBreakdown pb;
        bool pb_ok = power_sample_breakdown(&pb);
        BatteryInfo bInfo;
        bool bi_ok = battery_get_info(&bInfo);

        if (!pb_ok || !bi_ok) {
            if (tick == 0) printf("\033[H\033[2J");
            else printf("\033[H");
            printf(CLR_DIM "[" CLR_RESET CLR_BRIGHT "%c" CLR_RESET CLR_DIM "]" CLR_RESET " " CLR_BRIGHT "%s" CLR_RESET "  " CLR_BRIGHT "+%lds" CLR_RESET "\033[K\n\n", spinner, time_str, elapsed);
            printf("  read error\033[K\n\n");
            printf(CLR_DIM "────────────────────────────────────────────────────────" CLR_RESET "\033[K\n");
            printf(" " CLR_BRIGHT "[t]" CLR_RESET CLR_DIM " toggle hold/charge   " CLR_RESET CLR_BRIGHT "[e]" CLR_RESET CLR_DIM " export startup log   " CLR_RESET CLR_BRIGHT "[r]" CLR_RESET CLR_DIM " raw   " CLR_RESET CLR_BRIGHT "[q]" CLR_RESET CLR_DIM " quit" CLR_RESET "\033[K\n\033[J");
            fflush(stdout);
            sleep(1);
            tick++;
            continue;
        }

        bool isHold = (pb.ac_connected && !pb.is_charging && ((pb.not_charging_reason & 0x01000000) != 0) && abs(pb.battery_ma) < 100);
        if (pb.ac_connected && isHold) {
            hold_active_prior = true;
        } else if (pb.ac_connected && (pb.is_charging || pb.battery_ma >= 50)) {
            hold_active_prior = false;
        }

        // ADDENDUM 4: Plug cycle detection & Live reconciliation for TTY
        if (!prev_ac_connected && pb.ac_connected) {
            // Unplugged -> Replugged transition
            if (hold_active_prior || access("/tmp/byp.state", F_OK) == 0) {
                disable_bypass_and_resume_charging();
                log_step_record("plug_cycle", "defaulted to charging");
                hold_active_prior = false;

                // Re-sample registers immediately so this frame renders charging
                power_sample_breakdown(&pb);
                battery_get_info(&bInfo);

                isHold = (pb.ac_connected && !pb.is_charging && ((pb.not_charging_reason & 0x01000000) != 0) && abs(pb.battery_ma) < 100);
                settle_state = 2; // charging
                settle_ac = true;
                settle_start_time = now;
                is_settling = true;
                settle_agree_count = 0;
                time_in_state_cur = 2;
                state_start_time = now;
            }
        } else if (pb.ac_connected && (pb.battery_ma <= -50 || bInfo.amperage <= -50)) {
            // AC attached with battery discharging: state error, run resume path immediately
            disable_bypass_and_resume_charging();
            log_step_record("plug_cycle", "defaulted to charging");
            hold_active_prior = false;

            power_sample_breakdown(&pb);
            battery_get_info(&bInfo);

            isHold = (pb.ac_connected && !pb.is_charging && ((pb.not_charging_reason & 0x01000000) != 0) && abs(pb.battery_ma) < 100);
            settle_state = 2;
            settle_ac = true;
            settle_start_time = now;
            is_settling = true;
            settle_agree_count = 0;
            time_in_state_cur = 2;
            state_start_time = now;
        }
        prev_ac_connected = pb.ac_connected;

        int ad_w = get_adapter_watts();
        bool isCharging = (pb.ac_connected && (pb.is_charging || pb.battery_ma >= 50));
        
        int cur_state = !pb.ac_connected ? 3 : (isHold ? 1 : 2);
        const char *cur_state_str = (cur_state == 1) ? "hold" : ((cur_state == 2) ? "charging" : "on battery");

        // Time in state calculation
        if (time_in_state_cur != cur_state) {
            time_in_state_cur = cur_state;
            state_start_time = now;
        }
        long state_elapsed = (long)(now - state_start_time);
        int state_m = (int)(state_elapsed / 60);
        int state_s = (int)(state_elapsed % 60);
        char time_in_state_str[32];
        if (state_m > 0) {
            snprintf(time_in_state_str, sizeof(time_in_state_str), "(%dm %02ds)", state_m, state_s);
        } else {
            snprintf(time_in_state_str, sizeof(time_in_state_str), "(%ds)", state_s);
        }

        // Settling rule evaluation (up to 10s or until 2 consecutive samples agree within 5%)
        bool state_flipped = (settle_state != -1 && cur_state != settle_state);
        bool plug_changed  = (settle_state != -1 && pb.ac_connected != settle_ac);
        if (settle_state == -1 || state_flipped || plug_changed) {
            settle_state = cur_state;
            settle_ac = pb.ac_connected;
            settle_start_time = now;
            is_settling = true;
            settle_agree_count = 0;
            settle_prev_batt_w = -999.0;
            settle_prev_load_w = -999.0;
        }

        if (is_settling) {
            double dt_settle = difftime(now, settle_start_time);
            if (dt_settle >= 10.0) {
                is_settling = false;
            } else {
                if (settle_prev_batt_w != -999.0 && settle_prev_load_w != -999.0) {
                    double diff_b = fabs(pb.battery_w - settle_prev_batt_w);
                    double denom_b = fmax(fabs(pb.battery_w), 1.0);
                    double diff_l = fabs(pb.total_system_w - settle_prev_load_w);
                    double denom_l = fmax(fabs(pb.total_system_w), 1.0);
                    if ((diff_b / denom_b <= 0.05) && (diff_l / denom_l <= 0.05)) {
                        settle_agree_count++;
                        if (settle_agree_count >= 1) {
                            is_settling = false;
                        }
                    } else {
                        settle_agree_count = 0;
                    }
                }
                settle_prev_batt_w = pb.battery_w;
                settle_prev_load_w = pb.total_system_w;
            }
        }

        // Cross-Check Band calculation (compare load_W with SoC + DRAM + PMIC + PPMC rails)
        double rail_sum_w = (double)(pb.soc_w + pb.dram_w + pb.pmic_w + pb.pkg_w);
        double load_w = pb.total_system_w;
        double ref_max = fmax(load_w, rail_sum_w);
        bool cross_check_disagree = false;
        if (ref_max > 0.5) {
            if (fabs(load_w - rail_sum_w) / ref_max > 0.40) {
                cross_check_disagree = true;
            }
        }
        if (cross_check_disagree) {
            cross_check_disagree_count++;
        } else {
            cross_check_disagree_count = 0;
        }
        bool show_rail_sum_asterisk = (cross_check_disagree_count >= 3);

        // Pending Action Evaluation (ADDENDUM 6: 15s verify window, pending marker active to 60s, honest single record)
        if (pending_act.active) {
            if (!pending_act.completed) {
                struct timeval tv_now;
                gettimeofday(&tv_now, NULL);
                double cur_t = tv_now.tv_sec + (tv_now.tv_usec / 1000000.0);
                double el = cur_t - pending_act.start_time;

                bool verified = false;
                if (pending_act.target_state == 2) {
                    if ((bInfo.acAttached && bInfo.isCharging && bInfo.amperage > 500 && bInfo.notChargingReason == 0) ||
                        (g_action_worker_args.finished && g_action_worker_args.result && bInfo.isCharging && bInfo.notChargingReason == 0)) {
                        verified = true;
                    }
                } else if (pending_act.target_state == 1) {
                    if ((bInfo.acAttached && !bInfo.isCharging && ((bInfo.notChargingReason & 0x01000000) != 0) && abs(bInfo.amperage) < 100) ||
                        (g_action_worker_args.finished && g_action_worker_args.result && ((bInfo.notChargingReason & 0x01000000) != 0))) {
                        verified = true;
                    }
                }

                if (verified) {
                    pending_act.completed = true;
                    pending_act.success = true;
                    pending_act.elapsed_sec = el;
                    pending_act.display_until = now + 3;
                    transient_until = now + 3;
                    if (el <= 15.0) {
                        if (pending_act.target_state == 2) {
                            snprintf(transient_msg, sizeof(transient_msg), "[t] charging resumed [%+d mA] %.1f s", bInfo.amperage, el);
                            char res_str[128];
                            snprintf(res_str, sizeof(res_str), "charging resumed [+%d mA] %.1f s", bInfo.amperage, el);
                            log_step_record("key:t", res_str);
                            hold_active_prior = false;
                        } else {
                            snprintf(transient_msg, sizeof(transient_msg), "[t] hold engaged [ok] %.1f s", el);
                            char res_str[128];
                            snprintf(res_str, sizeof(res_str), "hold engaged [ok] %.1f s", el);
                            log_step_record("key:t", res_str);
                            hold_active_prior = true;
                        }
                    } else {
                        // Verified late (> 15s and <= 60s)
                        if (pending_act.target_state == 2) {
                            snprintf(transient_msg, sizeof(transient_msg), "[t] charging resumed verified %.1f s late", el);
                            char res_str[128];
                            snprintf(res_str, sizeof(res_str), "charging verified %.1f s late", el);
                            log_step_record("key:t", res_str);
                            hold_active_prior = false;
                        } else {
                            snprintf(transient_msg, sizeof(transient_msg), "[t] hold engaged verified %.1f s late", el);
                            char res_str[128];
                            snprintf(res_str, sizeof(res_str), "hold engaged verified %.1f s late", el);
                            log_step_record("key:t", res_str);
                            hold_active_prior = true;
                        }
                    }
                } else if (el >= 60.0) {
                    // Only record timeout/fail when no flip lands within 60 s
                    pending_act.completed = true;
                    pending_act.success = false;
                    pending_act.elapsed_sec = el;
                    pending_act.display_until = now + 3;
                    transient_until = now + 3;
                    if (pending_act.target_state == 2) {
                        snprintf(transient_msg, sizeof(transient_msg), "[t] [FAIL] NCR: 0x%08x, IsCharging: %s, Flow: %+d mA", bInfo.notChargingReason, bInfo.isCharging ? "Yes" : "No", bInfo.amperage);
                    } else {
                        snprintf(transient_msg, sizeof(transient_msg), "[t] [FAIL] NCR: 0x%08x, IsCharging: %s, Current: %+d mA", bInfo.notChargingReason, bInfo.isCharging ? "Yes" : "No", bInfo.amperage);
                    }
                    log_step_record("key:t", "timeout [FAIL] unverified after 60 s");
                }
            } else {
                if (now >= pending_act.display_until) {
                    pending_act.active = false;
                    pending_act.completed = false;
                    transient_msg[0] = '\0';
                }
            }
        }

        // State change detector & session recording
        if (pending_act.active) {
            // A state flip caused by the tool's own key action is credited to action=key:<k>, and NEVER recorded as action=observed,external
            last_state = cur_state;
        } else {
            if (last_state != 0 && last_state != cur_state) {
                char flip_res[64];
                snprintf(flip_res, sizeof(flip_res), "state changed to %s", cur_state_str);
                log_step_record("observed,external", flip_res);
            } else {
                char frame_res[64];
                snprintf(frame_res, sizeof(frame_res), "state:%s", cur_state_str);
                log_step_record("frame", frame_res);
            }
            last_state = cur_state;
        }

        // State color
        const char *state_clr;
        if (!pb.ac_connected) {
            state_clr = CLR_YELLOW;
        } else if (isHold) {
            state_clr = CLR_CYAN;
        } else {
            state_clr = CLR_GREEN;
        }

        int pct = pb.percentage;
        if (pct < 0) pct = 0; if (pct > 100) pct = 100;
        int filled = pct / 10;
        if (filled < 0) filled = 0; if (filled > 10) filled = 10;
        int empty = 10 - filled;

        char bar_filled[64] = {0};
        char bar_empty[64] = {0};
        char *pbf = bar_filled;
        char *pbe = bar_empty;
        for (int i = 0; i < filled; i++) pbf += sprintf(pbf, "█");
        for (int i = 0; i < empty; i++) pbe += sprintf(pbe, "░");

        const char *batt_word;
        if (!pb.ac_connected) batt_word = "discharging";
        else if (isHold || abs(pb.battery_ma) < 50) batt_word = "resting";
        else batt_word = "charging";

        // Flow glyphs & Activity detection
        bool laptop_active = (pb.total_system_w > 0.1);
        bool batt_active   = (fabs(pb.battery_w) > 0.1 && !isHold && abs(pb.battery_ma) >= 50);

        char laptop_glyphs[128];
        char batt_glyphs[128];

        if (pb.ac_connected) {
            format_flow_glyphs(laptop_glyphs, sizeof(laptop_glyphs), laptop_active, false, state_clr, tick);
            format_flow_glyphs(batt_glyphs, sizeof(batt_glyphs), batt_active, isHold || abs(pb.battery_ma) < 50, state_clr, tick);
        } else {
            bool batt_discharging_active = (laptop_active || fabs(pb.battery_w) > 0.1);
            format_flow_glyphs(batt_glyphs, sizeof(batt_glyphs), batt_discharging_active, false, CLR_YELLOW, tick);
        }

        char batt_detail[64];
        if (isHold || abs(pb.battery_ma) < 50) {
            snprintf(batt_detail, sizeof(batt_detail), "0 mA, valve closed");
        } else if (isCharging || pb.battery_ma >= 50) {
            if (is_settling) snprintf(batt_detail, sizeof(batt_detail), "~+%.1f A", (double)pb.battery_ma / 1000.0);
            else snprintf(batt_detail, sizeof(batt_detail), "+%.1f A", (double)pb.battery_ma / 1000.0);
        } else if (!pb.ac_connected) {
            if (is_settling) snprintf(batt_detail, sizeof(batt_detail), "~-%.1f A", -(double)pb.battery_ma / 1000.0);
            else snprintf(batt_detail, sizeof(batt_detail), "-%.1f A", -(double)pb.battery_ma / 1000.0);
        } else {
            if (is_settling) snprintf(batt_detail, sizeof(batt_detail), "~+%.1f A", (double)fmax(pb.battery_ma, 0) / 1000.0);
            else snprintf(batt_detail, sizeof(batt_detail), "+%.1f A", (double)fmax(pb.battery_ma, 0) / 1000.0);
        }

        // Power number strings with settling tildes and cross-check asterisk
        char laptop_w_str[32];
        char batt_w_str[32];
        char adapter_str[32];

        if (show_rail_sum_asterisk) {
            if (is_settling) snprintf(laptop_w_str, sizeof(laptop_w_str), "~%4.1f W*", rail_sum_w);
            else snprintf(laptop_w_str, sizeof(laptop_w_str), " %4.1f W*", rail_sum_w);
        } else {
            if (is_settling) snprintf(laptop_w_str, sizeof(laptop_w_str), "~%4.1f W", pb.total_system_w);
            else snprintf(laptop_w_str, sizeof(laptop_w_str), " %4.1f W", pb.total_system_w);
        }

        if (is_settling) snprintf(batt_w_str, sizeof(batt_w_str), "~%4.1f W", fabs(pb.battery_w));
        else snprintf(batt_w_str, sizeof(batt_w_str), "%5.1f W", fabs(pb.battery_w));

        int disp_ad_w = ad_w > 0 ? ad_w : (int)(pb.dc_in_w + 0.5f);
        if (is_settling) snprintf(adapter_str, sizeof(adapter_str), "adapter ~%d W", disp_ad_w);
        else snprintf(adapter_str, sizeof(adapter_str), "adapter %d W", disp_ad_w);

        // Estimate line under battery bar (ADDENDUM 6: omitted entirely while on hold)
        char est_line_colored[256];
        est_line_colored[0] = '\0';
        if (!pb.ac_connected) {
            double dischg_w = pb.total_system_w > 0.1 ? pb.total_system_w : fabs(pb.battery_w);
            if (dischg_w < 0.1) dischg_w = 0.1;
            int mins = 0;
            if (bInfo.avgTimeToEmpty > 0 && bInfo.avgTimeToEmpty < 65535) {
                mins = bInfo.avgTimeToEmpty;
            } else {
                int cur_cap = bInfo.remainingCapacity > 0 ? bInfo.remainingCapacity : (bInfo.percentage * 50);
                double rem_wh = ((double)cur_cap * (double)pb.battery_mv) / 1000000.0;
                mins = (int)((rem_wh / dischg_w) * 60.0 + 0.5);
            }
            if (mins < 1) mins = 1;
            if (mins >= 60) snprintf(est_line_colored, sizeof(est_line_colored), CLR_YELLOW "~%dh %02dm left at " CLR_RESET CLR_BRIGHT "%.1f W" CLR_RESET, mins / 60, mins % 60, dischg_w);
            else snprintf(est_line_colored, sizeof(est_line_colored), CLR_YELLOW "~%dm left at " CLR_RESET CLR_BRIGHT "%.1f W" CLR_RESET, mins, dischg_w);
        } else if (isHold || !pb.is_charging || pb.not_charging_reason != 0 || pb.battery_ma < 500) {
            est_line_colored[0] = '\0';
        } else {
            int full_cap = bInfo.fullChargeCapacity > 0 ? bInfo.fullChargeCapacity : (bInfo.designCapacity > 0 ? bInfo.designCapacity : 5292);
            int cur_cap = bInfo.remainingCapacity > 0 ? bInfo.remainingCapacity : (bInfo.percentage * full_cap / 100);
            int rem_mah = full_cap - cur_cap;
            if (rem_mah < 0) rem_mah = 0;
            double cur_a = (double)pb.battery_ma / 1000.0;
            if (cur_a < 0.5) cur_a = 0.5;
            int mins = (int)((rem_mah / (cur_a * 1000.0)) * 60.0 + 0.5);
            if (mins < 1) mins = 1;
            if (mins >= 60) snprintf(est_line_colored, sizeof(est_line_colored), CLR_GREEN "full in ~%dh %02dm at " CLR_RESET CLR_BRIGHT "%.1f A" CLR_RESET, mins / 60, mins % 60, cur_a);
            else snprintf(est_line_colored, sizeof(est_line_colored), CLR_GREEN "full in ~%dm at " CLR_RESET CLR_BRIGHT "%.1f A" CLR_RESET, mins, cur_a);
        }

        char batt_word_colored[64];
        if (strcmp(batt_word, "charging") == 0) {
            snprintf(batt_word_colored, sizeof(batt_word_colored), CLR_GREEN "charging" CLR_RESET);
        } else if (strcmp(batt_word, "resting") == 0) {
            snprintf(batt_word_colored, sizeof(batt_word_colored), CLR_CYAN "resting" CLR_RESET);
        } else {
            snprintf(batt_word_colored, sizeof(batt_word_colored), CLR_YELLOW "%s" CLR_RESET, batt_word);
        }

        // Yellow WARN line evaluation
        uint16_t c1 = pb.cell1_mv, c2 = pb.cell2_mv, c3 = pb.cell3_mv;
        uint16_t cmin = c1, cmax = c1;
        if (c2 > 0 && c2 < cmin) cmin = c2;
        if (c2 > cmax) cmax = c2;
        if (c3 > 0 && c3 < cmin) cmin = c3;
        if (c3 > cmax) cmax = c3;
        uint16_t cell_spread = (cmax >= cmin && cmin > 0) ? (cmax - cmin) : 0;

        bool has_warn = (bInfo.temperature > 40.0 || cell_spread > 30);
        char warn_buf[128] = {0};
        if (has_warn) {
            if (bInfo.temperature > 40.0 && cell_spread > 30) {
                snprintf(warn_buf, sizeof(warn_buf), "WARN: high temp (%.1fC) | cell spread (%u mV)", bInfo.temperature, cell_spread);
            } else if (bInfo.temperature > 40.0) {
                snprintf(warn_buf, sizeof(warn_buf), "WARN: high temp (%.1fC)", bInfo.temperature);
            } else {
                snprintf(warn_buf, sizeof(warn_buf), "WARN: cell spread (%u mV)", cell_spread);
            }
        }

        // Home cursor / Clear
        if (tick == 0) printf("\033[H\033[2J");
        else printf("\033[H");

        // Header: [spinner] wall-clock, +elapsed (ADDENDUM 6: state word renders only once on battery line)
        printf(CLR_DIM "[" CLR_RESET CLR_BRIGHT "%c" CLR_RESET CLR_DIM "]" CLR_RESET " " CLR_BRIGHT "%s" CLR_RESET "  " CLR_BRIGHT "+%lds" CLR_RESET "\033[K\n\n",
               spinner, time_str, elapsed);

        // Body: Active flow line contrast (Bold and bright in state color with progressive animated arrows vs Dim inactive)
        if (pb.ac_connected) {
            // Laptop Flow Line
            if (laptop_active) {
                printf(CLR_BRIGHT "  WALL " CLR_RESET "%s" CLR_BRIGHT " laptop    %s    %s" CLR_RESET "\033[K\n",
                       laptop_glyphs, laptop_w_str, adapter_str);
            } else {
                printf(CLR_DIM "  WALL " CLR_RESET "%s" CLR_DIM " laptop    %s    %s" CLR_RESET "\033[K\n",
                       laptop_glyphs, laptop_w_str, adapter_str);
            }

            // Battery Flow Line
            if (batt_active) {
                printf(CLR_BRIGHT "  WALL " CLR_RESET "%s" CLR_BRIGHT " battery   %s    %s" CLR_RESET "\033[K\n\n",
                       batt_glyphs, batt_w_str, batt_detail);
            } else {
                printf(CLR_DIM "  WALL " CLR_RESET "%s" CLR_DIM " battery   %s    %s" CLR_RESET "\033[K\n\n",
                       batt_glyphs, batt_w_str, batt_detail);
            }
        } else {
            // Wall line unplugged
            printf(CLR_DIM "  wall      unplugged" CLR_RESET "\033[K\n");

            // Battery line active on battery
            if (laptop_active || fabs(pb.battery_w) > 0.1) {
                printf(CLR_BRIGHT "  BATT " CLR_RESET "%s" CLR_BRIGHT " laptop    %s    %s" CLR_RESET "\033[K\n\n",
                       batt_glyphs, laptop_w_str, batt_detail);
            } else {
                printf(CLR_DIM "  BATT " CLR_RESET "%s" CLR_DIM " laptop    %s    %s" CLR_RESET "\033[K\n\n",
                       batt_glyphs, laptop_w_str, batt_detail);
            }
        }

        // Battery Bar: State word once on battery line in state color, next to % and time-in-state
        printf("  " CLR_DIM "battery [" CLR_RESET CLR_BRIGHT "%s" CLR_RESET CLR_DIM "%s]" CLR_RESET " " CLR_BRIGHT "%d%%" CLR_RESET "  %s  " CLR_DIM "%s" CLR_RESET "\033[K\n",
               bar_filled, bar_empty, pct, batt_word_colored, time_in_state_str);

        // Estimate line under battery bar (ADDENDUM 6: omitted entirely while on hold)
        if (cur_state != 1 && est_line_colored[0] != '\0') {
            printf("  %s\033[K\n\n", est_line_colored);
        } else {
            printf("\n");
        }

        // Summary (ADDENDUM 6: dim prose \033[2m; only % and W/A numbers stay bright; state verbs not colored)
        if (!pb.ac_connected) {
            printf("  " CLR_DIM "> no wall power. battery is running the laptop." CLR_RESET "\033[K\n");
        } else if (isHold || abs(pb.battery_ma) < 50) {
            printf("  " CLR_DIM "> wall is running the laptop. battery is resting at " CLR_RESET CLR_BRIGHT "%d%%" CLR_RESET CLR_DIM "." CLR_RESET "\033[K\n", pct);
        } else {
            double chg_a = (double)fmax(pb.battery_ma, 0) / 1000.0;
            if (is_settling) {
                printf("  " CLR_DIM "> wall is running the laptop and charging the battery at " CLR_RESET CLR_BRIGHT "~%.1f A" CLR_RESET CLR_DIM "." CLR_RESET "\033[K\n", chg_a);
            } else {
                printf("  " CLR_DIM "> wall is running the laptop and charging the battery at " CLR_RESET CLR_BRIGHT "%.1f A" CLR_RESET CLR_DIM "." CLR_RESET "\033[K\n", chg_a);
            }
        }

        // Raw
        if (show_raw) {
            printf("\n" CLR_DIM "  raw: ncr=0x%08x isChg=%d amp=%+dmA pmu=%d load=%.1fW rails=%.1fW cells=%u/%u/%u mV temp=%.1fC" CLR_RESET "\033[K\n",
                   pb.not_charging_reason, pb.is_charging ? 1 : 0, pb.battery_ma, bInfo.pmuConfigured,
                   pb.total_system_w, rail_sum_w, pb.cell1_mv, pb.cell2_mv, pb.cell3_mv, bInfo.temperature);
        }

        // Yellow WARN line (only when temp > 40C or cell spread > 30 mV)
        if (has_warn) {
            printf("\n  " CLR_YELLOW "%s" CLR_RESET "\033[K\n", warn_buf);
        }

        // Footer (ADDENDUM 6: live elapsed seconds in footer [t] [|] resuming charging... 7s / unverified after 15 s)
        printf(CLR_DIM "────────────────────────────────────────────────────────" CLR_RESET "\033[K\n");
        if (pending_act.active && !pending_act.completed) {
            char spin_c = spinner_chars[pending_act.spinner_tick % 4];
            struct timeval tv_now_ft;
            gettimeofday(&tv_now_ft, NULL);
            double cur_t_ft = tv_now_ft.tv_sec + (tv_now_ft.tv_usec / 1000000.0);
            double el_ft = cur_t_ft - pending_act.start_time;
            int el_s = (int)el_ft;

            if (el_ft < 15.0) {
                if (pending_act.target_state == 2) {
                    printf(" " CLR_BRIGHT "[t]" CLR_RESET " " CLR_GREEN "[%c]" CLR_RESET " " CLR_DIM "resuming charging... %ds" CLR_RESET "\033[K\n", spin_c, el_s);
                } else {
                    printf(" " CLR_BRIGHT "[t]" CLR_RESET " " CLR_CYAN "[%c]" CLR_RESET " " CLR_DIM "engaging hold... %ds" CLR_RESET "\033[K\n", spin_c, el_s);
                }
            } else {
                printf(" " CLR_BRIGHT "[t]" CLR_RESET " " CLR_YELLOW "unverified after 15 s, still watching" CLR_RESET "\033[K\n");
            }
        } else if (now < transient_until && transient_msg[0] != '\0') {
            if (strstr(transient_msg, "[FAIL]")) {
                printf(" " CLR_YELLOW "%s" CLR_RESET "\033[K\n", transient_msg);
            } else if (strstr(transient_msg, "hold engaged")) {
                if (strstr(transient_msg, "late")) {
                    const char *v_part = strstr(transient_msg, "verified");
                    printf(" " CLR_BRIGHT "[t]" CLR_RESET " " CLR_CYAN "hold engaged" CLR_RESET " " CLR_YELLOW "%s" CLR_RESET "\033[K\n", v_part ? v_part : transient_msg + 4);
                } else {
                    const char *ok_part = strstr(transient_msg, "[ok]");
                    if (ok_part) {
                        printf(" " CLR_BRIGHT "[t]" CLR_RESET " " CLR_CYAN "hold engaged" CLR_RESET " " CLR_BRIGHT "[ok]" CLR_RESET "%s\033[K\n", ok_part + 4);
                    } else {
                        printf(" " CLR_BRIGHT "[t]" CLR_RESET " " CLR_CYAN "hold engaged" CLR_RESET " " CLR_BRIGHT "[ok]" CLR_RESET " %s\033[K\n", transient_msg + 17);
                    }
                }
            } else if (strstr(transient_msg, "charging resumed")) {
                if (strstr(transient_msg, "late")) {
                    const char *v_part = strstr(transient_msg, "verified");
                    printf(" " CLR_BRIGHT "[t]" CLR_RESET " " CLR_GREEN "charging resumed" CLR_RESET " " CLR_YELLOW "%s" CLR_RESET "\033[K\n", v_part ? v_part : transient_msg + 4);
                } else {
                    const char *flow_bracket = strstr(transient_msg, "resumed [");
                    if (flow_bracket) {
                        printf(" " CLR_BRIGHT "[t]" CLR_RESET " " CLR_GREEN "charging resumed" CLR_RESET " " CLR_GREEN "%s" CLR_RESET "\033[K\n", flow_bracket + 8);
                    } else {
                        printf(" " CLR_BRIGHT "[t]" CLR_RESET " " CLR_GREEN "charging resumed" CLR_RESET " %s\033[K\n", transient_msg + 21);
                    }
                }
            } else if (strncmp(transient_msg, "[e]", 3) == 0) {
                printf(" " CLR_BRIGHT "[e]" CLR_RESET " %s\033[K\n", transient_msg + 4);
            } else {
                printf(" %s\033[K\n", transient_msg);
            }
        } else {
            printf(" " CLR_BRIGHT "[t]" CLR_RESET CLR_DIM " toggle hold/charge   " CLR_RESET CLR_BRIGHT "[e]" CLR_RESET CLR_DIM " export startup log   " CLR_RESET CLR_BRIGHT "[r]" CLR_RESET CLR_DIM " raw   " CLR_RESET CLR_BRIGHT "[q]" CLR_RESET CLR_DIM " quit" CLR_RESET "\033[K\n");
        }
        printf("\033[J");
        fflush(stdout);

        // Wait up to 1 second with 50ms slices for input (2 slices = 100ms when action pending)
        int total_slices = (pending_act.active && !pending_act.completed) ? 2 : 20;
        for (int slice = 0; slice < total_slices && g_live_running; slice++) {
            fd_set fds;
            FD_ZERO(&fds);
            FD_SET(STDIN_FILENO, &fds);
            struct timeval tv = { .tv_sec = 0, .tv_usec = 50000 };
            int ret = select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv);
            if (ret > 0 && FD_ISSET(STDIN_FILENO, &fds)) {
                char ch = 0;
                int n = read(STDIN_FILENO, &ch, 1);
                if (n <= 0) {
                    g_live_running = false;
                    break;
                }
                if (ch == 'q' || ch == 'Q' || ch == 3) {
                    // Key echo: [q] [\] quitting...
                    printf(CLR_DIM "────────────────────────────────────────────────────────" CLR_RESET "\033[K\n");
                    printf(" " CLR_BRIGHT "[q]" CLR_RESET " " CLR_BRIGHT "[\\]" CLR_RESET " " CLR_DIM "quitting..." CLR_RESET "\033[K\n\033[J");
                    fflush(stdout);
                    log_step_record("key:q", "quit");
                    usleep(120000);
                    g_live_running = false;
                    break;
                } else if (ch == 'r' || ch == 'R') {
                    // Key echo: [r] [-] toggling raw...
                    printf(CLR_DIM "────────────────────────────────────────────────────────" CLR_RESET "\033[K\n");
                    printf(" " CLR_BRIGHT "[r]" CLR_RESET " " CLR_BRIGHT "[-]" CLR_RESET " " CLR_DIM "toggling raw..." CLR_RESET "\033[K\n\033[J");
                    fflush(stdout);
                    show_raw = !show_raw;
                    log_step_record("key:r", show_raw ? "toggle raw on" : "toggle raw off");
                    usleep(80000);
                    break;
                } else if (ch == 'e' || ch == 'E') {
                    // Key echo: [e] [/] writing session log...
                    printf(CLR_DIM "────────────────────────────────────────────────────────" CLR_RESET "\033[K\n");
                    printf(" " CLR_BRIGHT "[e]" CLR_RESET " " CLR_BRIGHT "[/]" CLR_RESET " " CLR_DIM "writing session log..." CLR_RESET "\033[K\n\033[J");
                    fflush(stdout);

                    char exp_path[256] = {0};
                    log_step_record("key:e", "writing session log");
                    int lines = export_session_log(exp_path, sizeof(exp_path));
                    if (lines >= 0) {
                        snprintf(transient_msg, sizeof(transient_msg), "[e] written: %s (%d lines)", exp_path, lines);
                    } else {
                        snprintf(transient_msg, sizeof(transient_msg), "[e] [FAIL] failed to write export log");
                    }
                    transient_until = time(NULL) + 3;
                    break;
                } else if (ch == 't' || ch == 'T') {
                    if (pending_act.active && !pending_act.completed) {
                        break;
                    }
                    if (pending_act.thread_active) {
                        pthread_join(pending_act.thread, NULL);
                        pending_act.thread_active = false;
                    }

                    BatteryInfo bCur;
                    battery_get_info(&bCur);
                    bool isCurHold = (bCur.acAttached && !bCur.isCharging && ((bCur.notChargingReason & 0x01000000) != 0));

                    struct timeval tv_start;
                    gettimeofday(&tv_start, NULL);

                    pending_act.active = true;
                    pending_act.key = 't';
                    pending_act.target_state = isCurHold ? 2 : 1;
                    pending_act.start_time = tv_start.tv_sec + (tv_start.tv_usec / 1000000.0);
                    pending_act.spinner_tick = 0;
                    pending_act.completed = false;
                    pending_act.success = false;
                    pending_act.elapsed_sec = 0.0;
                    pending_act.display_until = 0;
                    transient_msg[0] = '\0';
                    transient_until = 0;

                    g_action_worker_args.target_state = pending_act.target_state;
                    g_action_worker_args.finished = false;
                    g_action_worker_args.result = false;

                    if (pthread_create(&pending_act.thread, NULL, action_worker_thread, &g_action_worker_args) == 0) {
                        pending_act.thread_active = true;
                    }

                    break;
                }
            }
        }
        if (pending_act.active && !pending_act.completed) {
            pending_act.spinner_tick++;
        }
        tick++;
    }

    if (pending_act.thread_active) {
        pthread_join(pending_act.thread, NULL);
        pending_act.thread_active = false;
    }

    disable_raw_mode();
    printf("\n");
    fflush(stdout);
}

static int handle_verb_on(void) {
    struct timeval tv_start, tv_end;
    gettimeofday(&tv_start, NULL);

    log_step_record("launch", "byp on");

    DotMeshCtx dot_ctx = { .stop = false, .stage = 0 };
    pthread_t dot_thread;
    bool has_thread = false;
    if (isatty(STDOUT_FILENO)) {
        if (pthread_create(&dot_thread, NULL, dot_mesh_thread_func, &dot_ctx) == 0) {
            has_thread = true;
        }
    }

    dot_ctx.stage = 1; // verifying state
    engage_bypass_at_any_percentage();
    dot_ctx.stage = 2; // waiting for settle

    BatteryInfo bAfter;
    memset(&bAfter, 0, sizeof(bAfter));
    bool read_ok = false;
    int max_polls = isatty(STDOUT_FILENO) ? 20 : 8;
    for (int poll = 0; poll < max_polls; poll++) {
        if (battery_get_info(&bAfter)) {
            read_ok = true;
            if ((bAfter.notChargingReason & 0x01000000) != 0 || !bAfter.isCharging || abs(bAfter.amperage) < 100) {
                break;
            }
        }
        usleep(50000); // 50ms
    }
    if (!read_ok) read_ok = battery_get_info(&bAfter);

    if (has_thread) {
        dot_ctx.stop = true;
        pthread_join(dot_thread, NULL);
    }

    gettimeofday(&tv_end, NULL);
    double elapsed_sec = (tv_end.tv_sec - tv_start.tv_sec) + (tv_end.tv_usec - tv_start.tv_usec) / 1000000.0;

    // Truth-table verdict: hold is only real with AC attached, charging stopped,
    // NCR 0x01000000 and near-zero flow. Never print a blind checkmark.
    bool in_hold = read_ok && bAfter.acAttached && !bAfter.isCharging &&
                   ((bAfter.notChargingReason & 0x01000000) != 0) && abs(bAfter.amperage) < 100;

    if (!in_hold) {
        if (isatty(STDOUT_FILENO)) {
            printf(CLR_YELLOW "[FAIL]" CLR_RESET " bypass hold not confirmed after " CLR_BRIGHT "%.1f s" CLR_RESET "\n", elapsed_sec);
        } else {
            printf("[FAIL] bypass hold not confirmed after %.1f s\n", elapsed_sec);
        }
        log_step_record("verb:on", "bypass hold NOT confirmed");
        return 1;
    }

    if (isatty(STDOUT_FILENO)) {
        printf("bypass charging enabled " CLR_BRIGHT "[✓]" CLR_RESET " " CLR_BRIGHT "%.1f s" CLR_RESET "\n", elapsed_sec);
    } else {
        printf("bypass charging enabled [✓] %.1f s\n", elapsed_sec);
    }
    char logline[128];
    snprintf(logline, sizeof(logline), "bypass charging enabled [ok] %.1f s", elapsed_sec);
    log_step_record("verb:on", logline);
    return 0;
}

static int handle_verb_off(void) {
    struct timeval tv_start, tv_end;
    gettimeofday(&tv_start, NULL);

    log_step_record("launch", "byp off");

    DotMeshCtx dot_ctx = { .stop = false, .stage = 0 };
    pthread_t dot_thread;
    bool has_thread = false;
    if (isatty(STDOUT_FILENO)) {
        if (pthread_create(&dot_thread, NULL, dot_mesh_thread_func, &dot_ctx) == 0) {
            has_thread = true;
        }
    }

    dot_ctx.stage = 1; // verifying state
    bool ok = disable_bypass_and_resume_charging();
    dot_ctx.stage = 2; // waiting for settle

    BatteryInfo bAfter;
    memset(&bAfter, 0, sizeof(bAfter));
    bool read_ok = false;
    int max_polls = isatty(STDOUT_FILENO) ? 20 : 8;
    for (int poll = 0; poll < max_polls; poll++) {
        if (battery_get_info(&bAfter)) {
            read_ok = true;
            if (ok && (bAfter.isCharging || bAfter.notChargingReason == 0 || bAfter.amperage > 0)) {
                break;
            }
        }
        usleep(50000); // 50ms
    }
    if (!read_ok) read_ok = battery_get_info(&bAfter);

    if (has_thread) {
        dot_ctx.stop = true;
        pthread_join(dot_thread, NULL);
    }

    gettimeofday(&tv_end, NULL);
    double elapsed_sec = (tv_end.tv_sec - tv_start.tv_sec) + (tv_end.tv_usec - tv_start.tv_usec) / 1000000.0;

    // Truth-table verdict: charging really resumed only with AC attached and
    // either an active charge or a zero not-charging reason.
    bool resumed = read_ok && bAfter.acAttached &&
                   (bAfter.isCharging || bAfter.notChargingReason == 0);

    if (!resumed) {
        if (isatty(STDOUT_FILENO)) {
            printf(CLR_YELLOW "[FAIL]" CLR_RESET " charging resume not confirmed after " CLR_BRIGHT "%.1f s" CLR_RESET "\n", elapsed_sec);
        } else {
            printf("[FAIL] charging resume not confirmed after %.1f s\n", elapsed_sec);
        }
        log_step_record("verb:off", "charging resume NOT confirmed");
        return 1;
    }

    if (isatty(STDOUT_FILENO)) {
        printf(CLR_GREEN "charging" CLR_RESET " resumed [" CLR_GREEN "%+d mA" CLR_RESET "] " CLR_BRIGHT "%.1f s" CLR_RESET "\n", bAfter.amperage, elapsed_sec);
    } else {
        printf("charging resumed [%+d mA] %.1f s\n", bAfter.amperage, elapsed_sec);
    }
    char logline[128];
    snprintf(logline, sizeof(logline), "charging resumed [+%d mA] %.1f s", bAfter.amperage, elapsed_sec);
    log_step_record("verb:off", logline);
    return 0;
}

static int handle_toggle(void) {
    BatteryInfo bInfo;
    if (!battery_get_info(&bInfo)) {
        if (isatty(STDOUT_FILENO)) printf(CLR_YELLOW "[FAIL]" CLR_RESET " registers unreadable\n");
        else printf("[FAIL] registers unreadable\n");
        return 3;
    }

    bool isHold = (bInfo.acAttached && !bInfo.isCharging && ((bInfo.notChargingReason & 0x01000000) != 0) && abs(bInfo.amperage) < 100);

    struct timeval tv_start, tv_end;
    gettimeofday(&tv_start, NULL);

    DotMeshCtx dot_ctx = { .stop = false, .stage = 0 };
    pthread_t dot_thread;
    bool has_thread = false;
    if (isatty(STDOUT_FILENO)) {
        if (pthread_create(&dot_thread, NULL, dot_mesh_thread_func, &dot_ctx) == 0) {
            has_thread = true;
        }
    }

    if (isHold) {
        dot_ctx.stage = 1;
        disable_bypass_and_resume_charging();
        dot_ctx.stage = 2;
    } else {
        dot_ctx.stage = 1;
        engage_bypass_at_any_percentage();
        dot_ctx.stage = 2;
    }

    BatteryInfo bAfter;
    if (isHold) {
        for (int poll = 0; poll < 5; poll++) {
            if (battery_get_info(&bAfter)) {
                if (bAfter.isCharging || bAfter.notChargingReason == 0 || bAfter.amperage > 0) break;
            }
            usleep(50000);
        }
    } else {
        for (int poll = 0; poll < 5; poll++) {
            if (battery_get_info(&bAfter)) {
                if ((bAfter.notChargingReason & 0x01000000) != 0 || !bAfter.isCharging || abs(bAfter.amperage) < 100) break;
            }
            usleep(50000);
        }
    }

    if (has_thread) {
        dot_ctx.stop = true;
        pthread_join(dot_thread, NULL);
    }

    gettimeofday(&tv_end, NULL);
    double elapsed_sec = (tv_end.tv_sec - tv_start.tv_sec) + (tv_end.tv_usec - tv_start.tv_usec) / 1000000.0;

    if (isHold) {
        if (isatty(STDOUT_FILENO)) {
            printf(CLR_GREEN "charging" CLR_RESET " resumed [" CLR_GREEN "%+d mA" CLR_RESET "] " CLR_BRIGHT "%.1f s" CLR_RESET "\n", bAfter.amperage, elapsed_sec);
        } else {
            printf("charging resumed [%+d mA] %.1f s\n", bAfter.amperage, elapsed_sec);
        }
        return 0;
    } else {
        if (isatty(STDOUT_FILENO)) {
            printf("bypass charging enabled " CLR_BRIGHT "[✓]" CLR_RESET " " CLR_BRIGHT "%.1f s" CLR_RESET "\n", elapsed_sec);
        } else {
            printf("bypass charging enabled [✓] %.1f s\n", elapsed_sec);
        }
        return 0;
    }
}

static void print_usage(const char *prog) {
    printf("byp -- macOS Charging Bypass & Power Telemetry Control v%s\n", VERSION);
    printf("Usage: %s [command]\n\n", prog);
    printf("Commands:\n");
    printf("  byp                     Open live power and bypass monitor\n");
    printf("  byp on                  Enable bypass charging / suspend battery charge\n");
    printf("  byp off                 Resume full normal battery charging\n");
    printf("  byp mon [--export]      Live monitor view (stream in non-TTY)\n");
    printf("  byp s                   One-line status summary\n");
    printf("  byp p                   Hardware power rails breakdown\n");
    printf("  byp t                   Toggle hold / charging\n");
    printf("  byp json [power]        Machine-readable JSON telemetry\n");
    printf("  byp help                Show command usage\n");
}

int main(int argc, char *argv[]) {
    setuid(0);
    seteuid(0);
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);

    if (argc < 2) {
        log_step_record("launch", "bare byp");
        run_calibration_sweep();
        live_view_run();
        return 0;
    }

    const char *cmd = argv[1];

    // ON / HOLD / BYPASS (on, -on, h, -h, hold, bypass)
    if (strcmp(cmd, "on") == 0 || strcmp(cmd, "-on") == 0 || strcmp(cmd, "h") == 0 ||
        strcmp(cmd, "-h") == 0 || strcmp(cmd, "hold") == 0 || strcmp(cmd, "bypass") == 0) {
        return handle_verb_on();
    }

    // OFF / CHARGE / FULL (off, -off, c, -c, f, -f, charge, full, resume)
    if (strcmp(cmd, "off") == 0 || strcmp(cmd, "-off") == 0 || strcmp(cmd, "c") == 0 ||
        strcmp(cmd, "-c") == 0 || strcmp(cmd, "f") == 0 || strcmp(cmd, "-f") == 0 ||
        strcmp(cmd, "charge") == 0 || strcmp(cmd, "full") == 0 || strcmp(cmd, "resume") == 0) {
        return handle_verb_off();
    }

    // MONITOR (mon, -m, -mon, log, w, watch)
    if (strcmp(cmd, "mon") == 0 || strcmp(cmd, "-m") == 0 || strcmp(cmd, "-mon") == 0 ||
        strcmp(cmd, "log") == 0 || strcmp(cmd, "w") == 0 || strcmp(cmd, "watch") == 0) {
        if (argc > 2 && (strcmp(argv[2], "--export") == 0 || strcmp(argv[2], "-e") == 0)) {
            char exp_path[256] = {0};
            int lines = export_session_log(exp_path, sizeof(exp_path));
            if (lines >= 0) {
                printf("written: %s (%d lines)\n", exp_path, lines);
                return 0;
            } else {
                fprintf(stderr, "failed to write export log\n");
                return 1;
            }
        }
        log_step_record("launch", "byp mon");
        run_calibration_sweep();
        live_view_run();
        return 0;
    }

    // STATUS (s, -s, st, status, info, i)
    if (strcmp(cmd, "s") == 0 || strcmp(cmd, "-s") == 0 || strcmp(cmd, "st") == 0 ||
        strcmp(cmd, "status") == 0 || strcmp(cmd, "info") == 0 || strcmp(cmd, "i") == 0) {
        print_status_quick();
        return 0;
    }

    // POWER RAILS (p, -p, power, rails)
    if (strcmp(cmd, "p") == 0 || strcmp(cmd, "-p") == 0 || strcmp(cmd, "power") == 0 ||
        strcmp(cmd, "rails") == 0) {
        print_power_breakdown();
        return 0;
    }

    // TOGGLE (t, -t, tog, toggle)
    if (strcmp(cmd, "t") == 0 || strcmp(cmd, "-t") == 0 || strcmp(cmd, "tog") == 0 || strcmp(cmd, "toggle") == 0) {
        return handle_toggle();
    }

    // JSON (j, -j, json)
    if (strcmp(cmd, "j") == 0 || strcmp(cmd, "-j") == 0 || strcmp(cmd, "json") == 0) {
        print_status(true);
        return 0;
    }

    // LOW POWER MODE (lpm, lowpower)
    if (strcmp(cmd, "lpm") == 0 || strcmp(cmd, "lowpower") == 0) {
        if (argc > 2) {
            setuid(0);
            if (strcmp(argv[2], "1") == 0 || strcmp(argv[2], "on") == 0 || strcmp(argv[2], "true") == 0) {
                return system("/usr/bin/pmset -a lowpowermode 1");
            } else if (strcmp(argv[2], "0") == 0 || strcmp(argv[2], "off") == 0 || strcmp(argv[2], "false") == 0) {
                return system("/usr/bin/pmset -a lowpowermode 0");
            }
        }
        return 1;
    }

    // EXPORT
    if (strcmp(cmd, "--export") == 0 || strcmp(cmd, "-e") == 0 || strcmp(cmd, "export") == 0) {
        char exp_path[256] = {0};
        int lines = export_session_log(exp_path, sizeof(exp_path));
        if (lines >= 0) {
            printf("written: %s (%d lines)\n", exp_path, lines);
            return 0;
        } else {
            fprintf(stderr, "failed to write export log\n");
            return 1;
        }
    }

    if (strcmp(cmd, "help") == 0 || strcmp(cmd, "--help") == 0 || strcmp(cmd, "-h") == 0 || strcmp(cmd, "?") == 0) {
        print_usage(argv[0]);
        return 0;
    }

    print_usage(argv[0]);
    return 1;
}
