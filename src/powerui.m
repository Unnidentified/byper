#import "powerui.h"
#import "battery.h"
#import "smc.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <stdio.h>
#import <unistd.h>
#import <errno.h>
#import <sys/stat.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/sysctl.h>
#import <sys/file.h>
#import <fcntl.h>

extern char **environ;

// Find PowerUIAgent PID via sysctl — no subprocess spawn needed
static pid_t find_powerui_pid(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    sysctl(mib, 4, NULL, &size, NULL, 0);
    struct kinfo_proc *procs = malloc(size);
    if (!procs) return 0;
    sysctl(mib, 4, procs, &size, NULL, 0);
    int count = (int)(size / sizeof(struct kinfo_proc));
    pid_t found = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, "PowerUIAgent") == 0) {
            found = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return found;
}

// Create a unique per-round LLDB script under /tmp (O_EXCL | O_NOFOLLOW, 0600)
// so a concurrent round can never truncate a live script and a local attacker
// can't pre-plant a symlink/fifo for the root lldb to consume. Returns the fd
// (caller writes, then close()) or -1.
static int open_lldb_script(char *path_buf, size_t bufsz) {
    static uint64_t seq = 0;
    for (int attempt = 0; attempt < 8; attempt++) {
        snprintf(path_buf, bufsz, "/tmp/byp_cmd_%d_%llu.lldb",
                 getpid(), (unsigned long long)(++seq));
        int fd = open(path_buf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd >= 0) return fd;
    }
    return -1;
}

// Run LLDB script — fire-and-forget with a detached worker: the CLI no longer
// blocks on the full lldb lifecycle (attach + symbol load + detach), whose
// occasional latency spikes were the rare toggle hang. The expr commits as
// soon as lldb evaluates it, so the caller's hardware verify poll
// (powerui_enable_hold / powerui_disable_hold) remains the sole success gate
// and still blocks until state is confirmed or its budget is exhausted.
//
// Serialization: two debuggers cannot hold PowerUIAgent's debug port at once,
// so sessions serialize on an flock'ed lock file shared across processes (each
// byper invocation is a fresh process). Acquisition is bounded at 3 s — on
// contention timeout this round skips (unlink script, return) instead of
// stacking a doomed attach.
//
// The worker is a forked child that spawns lldb as ITS child, reaps it, unlinks
// the script, and releases the lock. This process returns immediately and
// exits seconds later, so the worker is orphaned to launchd — no zombies, and
// cleanup survives the CLI's early exit.
#define BYP_LLDB_LOCK_PATH "/tmp/byp_lldb.lock"

// Blocking inline fallback (used only when fork fails): spawn lldb as our own
// child and wait for it — the pre-fix behavior, kept for robustness.
static void posix_spawn_and_wait(pid_t agent_pid, int stdin_fd, const char *script_path) {
    char pid_str[16];
    snprintf(pid_str, sizeof(pid_str), "%d", agent_pid);
    const char *lldb_argv[] = {
        "/usr/bin/sudo", "-S",
        "/usr/bin/lldb", "-p", pid_str,
        "--batch", "-s", script_path,
        NULL
    };

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, stdin_fd, STDIN_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    posix_spawn_file_actions_adddup2(&actions, devnull, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, devnull, STDERR_FILENO);

    pid_t child;
    if (posix_spawn(&child, "/usr/bin/sudo", &actions, NULL, (char *const *)lldb_argv, environ) == 0) {
        int st;
        while (waitpid(child, &st, 0) < 0 && errno == EINTR) {}
    }
    posix_spawn_file_actions_destroy(&actions);
    close(devnull);
}

static void run_lldb_script(const char *script_path) {
    int lock_fd = open(BYP_LLDB_LOCK_PATH, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    bool locked = false;
    if (lock_fd >= 0) {
        fchmod(lock_fd, 0666); // let non-root dev builds contend a root-made lock
        for (int i = 0; i < 1600; i++) { // ≤ 32 s — must cover the worker's 30 s
            // wedged-session kill: a slow-but-legit lldb detach is normal under
            // load, and skipping the round would silently drop the toggle.
            if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) { locked = true; break; }
            usleep(20000);
        }
    }
    if (!locked) {
        // A live session elsewhere holds the attach; skip this round.
        if (lock_fd >= 0) close(lock_fd);
        unlink(script_path);
        return;
    }

    pid_t agent_pid = find_powerui_pid();
    if (agent_pid == 0) {
        close(lock_fd);
        unlink(script_path); // nothing to attach to; verify poll gates truth
        return;
    }

    // Password goes into the pipe BEFORE the fork so both the worker and the
    // fork-failure fallback can hand lldb a ready stdin.
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        close(lock_fd);
        unlink(script_path);
        return;
    }
    ssize_t pw = write(pipefd[1], "REDACTED\n", 10);
    (void)pw;
    close(pipefd[1]);

    pid_t worker = fork();
    if (worker > 0) {
        // Parent: return immediately; worker owns the rest.
        close(pipefd[0]);
        close(lock_fd);
        return;
    }
    if (worker < 0) {
        // Fork failed: fall back to the old blocking inline path.
        posix_spawn_and_wait(agent_pid, pipefd[0], script_path);
        close(pipefd[0]);
        close(lock_fd);
        unlink(script_path);
        return;
    }

    // ── Worker (orphaned to launchd when the parent exits) ──
    // Detach from the CLI's stdio: the app reads the CLI's stdout pipe until
    // EOF, so the worker must not hold those descriptors open or the app would
    // block until this worker exits — silently undoing the fire-and-forget.
    int dn = open("/dev/null", O_RDWR);
    if (dn >= 0) {
        dup2(dn, STDIN_FILENO);
        dup2(dn, STDOUT_FILENO);
        dup2(dn, STDERR_FILENO);
        if (dn > STDERR_FILENO) close(dn);
    }

    char pid_str[16];
    snprintf(pid_str, sizeof(pid_str), "%d", agent_pid);
    const char *lldb_argv[] = {
        "/usr/bin/sudo", "-S",
        "/usr/bin/lldb", "-p", pid_str,
        "--batch", "-s", script_path,
        NULL
    };

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[0], STDIN_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    posix_spawn_file_actions_adddup2(&actions, devnull, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, devnull, STDERR_FILENO);

    pid_t child;
    if (posix_spawn(&child, "/usr/bin/sudo", &actions, NULL, (char *const *)lldb_argv, environ) == 0) {
        // Reap lldb, but never let a wedged session hold the lock forever:
        // cap the wait at 30 s, then SIGKILL so the next round can proceed.
        int st;
        bool exited = false;
        for (int i = 0; i < 1500; i++) {
            if (waitpid(child, &st, WNOHANG) != 0) { exited = true; break; }
            usleep(20000);
        }
        if (!exited) kill(child, SIGKILL);
        while (!exited && waitpid(child, &st, 0) < 0 && errno == EINTR) {}
    }
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[0]);
    close(devnull);
    close(lock_fd); // releases the flock for the next round
    unlink(script_path);
    _exit(0);
}


static void kick_kernel_battery_manager(void) {
    mach_port_t masterPort = kIOMainPortDefault;
    io_service_t service = IOServiceGetMatchingService(masterPort, IOServiceMatching("AppleSmartBatteryManager"));
    if (!service) service = IOServiceGetMatchingService(masterPort, IOServiceMatching("AppleSmartBattery"));
    if (service) {
        io_connect_t conn = 0;
        if (IOServiceOpen(service, mach_task_self(), 0, &conn) == kIOReturnSuccess && conn) {
            uint64_t inVal = 0, outVal = 0;
            uint32_t outCount = 1;
            IOConnectCallScalarMethod(conn, 0, &inVal, 1, &outVal, &outCount);
            IOConnectCallScalarMethod(conn, 1, &inVal, 1, &outVal, &outCount);
            IOConnectCallScalarMethod(conn, 5, &inVal, 1, &outVal, &outCount);
            IOConnectCallScalarMethod(conn, 6, &inVal, 1, &outVal, &outCount);
            IOServiceClose(conn);
        }
        IOObjectRelease(service);
    }
}



bool powerui_init(void) {
    return true;
}

bool powerui_get_status(NativeHoldStatus *status) {
    if (!status) return false;
    memset(status, 0, sizeof(NativeHoldStatus));

    @try {
        @autoreleasepool {
            status->isSupported = true;
            status->currentLimit = 100;

            NSDictionary *dict = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.apple.smartcharging.topoffprotection"];
            if (dict) {
                int st = [dict[@"currentState"] intValue];
                status->isOBCEngaged = (st == 1 || st == 7);
                NSDictionary *pls = dict[@"powerLogStatus"];
                if (pls && [pls isKindOfClass:[NSDictionary class]]) {
                    int lim = [pls[@"chargeLimitTargetSoC"] intValue];
                    if (lim >= 50 && lim <= 100) status->currentLimit = lim;
                    status->isMCLEnabled = ([pls[@"isManuallyChargeLimited"] intValue] != 0);
                    status->isEnabled = true;
                }
            }
            return true;
        }
    } @catch (NSException *e) { return false; }
}

// ─────────────────────────────────────────────────────────────────────────────
//  LLDB SCRIPT HELPERS — one session per spawn; re-spawned on verify failure
// ─────────────────────────────────────────────────────────────────────────────
static void spawn_hold_enable_script(int soc) {
    char lldb_path[64];
    int script_fd = open_lldb_script(lldb_path, sizeof(lldb_path));
    if (script_fd < 0) return;
    FILE *fp = fdopen(script_fd, "w");
    if (!fp) { close(script_fd); unlink(lldb_path); return; }
    fprintf(fp,
        "expr id $m = (id)[PowerUISmartChargeManager manager]; "
        "(void)[$m setOverrideAllSignals:1]; "
        "(void)[$m setReachedTargetSoC:1]; "
        "(void)[$m setBecameOBCEligible:1]; "
        "(void)[$m setDisabledUntilDate:nil]; "
        "(void)[$m setMclTargetSoC:%d]; "
        "(void)[$m setSavedMCLTargetSoC:%d]; "
        "(void)[$m engageManualChargeLimit]; "
        "(void)[$m handleNewBatteryLevel:%d whileExternalConnected:1 fullyCharged:0];\n"
        "quit\n", soc, soc, soc);
    fclose(fp); // closes script_fd
    run_lldb_script(lldb_path);
}

static void spawn_hold_disable_script(int soc) {
    char lldb_path[64];
    int script_fd = open_lldb_script(lldb_path, sizeof(lldb_path));
    if (script_fd < 0) return;
    FILE *fp = fdopen(script_fd, "w");
    if (!fp) { close(script_fd); unlink(lldb_path); return; }
    fprintf(fp,
        "expr id $m = (id)[PowerUISmartChargeManager manager]; "
        "id $c = (id)[$m chargingController]; "
        "(void)[$c clearAllChargeLimits]; "
        "(void)[$m clearManualChargeLimit]; "
        "(void)[$m clearMCLOverride]; "
        "(void)[$m disableMCL]; "
        "(void)[$m setReachedTargetSoC:0]; "
        "(void)[$m setOverrideAllSignals:0]; "
        "(void)[$m setBecameOBCEligible:0]; "
        "(void)[$m setDisabledUntilDate:nil]; "
        "(void)[$m enableCharging]; "
        "(void)[$m handleNewBatteryLevel:%d whileExternalConnected:1 fullyCharged:0];\n"
        "quit\n", soc);
    fclose(fp); // closes script_fd
    run_lldb_script(lldb_path);
}

// ─────────────────────────────────────────────────────────────────────────────
//  ENABLE HOLD — Charging On Hold at current SoC (Runtime In-Memory Hold)
// ─────────────────────────────────────────────────────────────────────────────
bool powerui_enable_hold(void) {
    @try {
        @autoreleasepool {
            BatteryInfo bInfo;
            battery_get_info(&bInfo);
            int soc = bInfo.percentage;
            if (soc <= 0 || soc > 100) soc = 80;

            // 1. Clear any disabledUntilDate lockout via LLDB (handled below)

            // 2. Drive PowerUISmartChargeManager in-process state machine
            spawn_hold_enable_script(soc);

            // 3. Notify subsystems & kick kernel driver
            notify_post("com.apple.powerui.smartchargestatuschanged");
            notify_post("com.apple.powerui.mclstatuschanged");
            kick_kernel_battery_manager();

            // 4. Live hardware verification poll (≤45s, 100ms intervals). If the
            // target state hasn't arrived after ~10s (observed: PowerUIAgent's
            // state machine transiently swallows an engage right after a clear),
            // re-spawn a fresh LLDB session — a later session provably lands it.
            for (int i = 0; i < 450; i++) {
                if (i > 0 && (i % 150) == 0) {
                    battery_get_info(&bInfo);
                    spawn_hold_enable_script(bInfo.percentage > 0 && bInfo.percentage <= 100 ? bInfo.percentage : soc);
                }
                usleep(100000);
                kick_kernel_battery_manager();
                battery_get_info(&bInfo);
                bool isHold = (bInfo.acAttached && !bInfo.isCharging &&
                               ((bInfo.notChargingReason & 0x01000000) != 0) &&
                               abs(bInfo.amperage) < 100);
                if (isHold) return true;
            }

            // Return hardware truth
            battery_get_info(&bInfo);
            return (bInfo.acAttached && !bInfo.isCharging && ((bInfo.notChargingReason & 0x01000000) != 0) && abs(bInfo.amperage) < 100);
        }
    } @catch (NSException *e) { return false; }
}

// ─────────────────────────────────────────────────────────────────────────────
//  DISABLE HOLD — Resume full fast charging to 100%
// ─────────────────────────────────────────────────────────────────────────────
bool powerui_disable_hold(void) {
    @try {
        @autoreleasepool {
            BatteryInfo bInfo;
            battery_get_info(&bInfo);
            int soc = bInfo.percentage;
            if (soc <= 0 || soc > 100) soc = 80;

            // 1. Reset PowerUISmartChargeManager & chargingController in-process state
            spawn_hold_disable_script(soc);

            // 2. Trigger immediate resume kick via LLDB (handled above)

            // 3. Clean up saved defaults overrides — single PlistBuddy call instead of 5 serial forks
            system("/usr/libexec/PlistBuddy -c 'Delete :overrideDesktopMode' -c 'Delete :isDesktopModeDevice' -c 'Delete :chargeTokenMCL' -c 'Delete :chargeTokenDEoC' -c 'Delete :reachedTargetSoC' /Library/Preferences/com.apple.PowerUI.plist > /dev/null 2>&1 || true");

            // 4. Notify subsystems & kick kernel driver
            notify_post("com.apple.powerui.smartchargestatuschanged");
            notify_post("com.apple.powerui.mclstatuschanged");
            kick_kernel_battery_manager();

            // 5. Live hardware verification poll (≤45s, 100ms intervals). If the
            // target state hasn't arrived after ~10s (observed: PowerUIAgent's
            // state machine transiently swallows the resume right after an
            // engage), re-spawn a fresh LLDB session — a later session lands it.
            for (int i = 0; i < 450; i++) {
                if (i > 0 && (i % 150) == 0) {
                    battery_get_info(&bInfo);
                    spawn_hold_disable_script(bInfo.percentage > 0 && bInfo.percentage <= 100 ? bInfo.percentage : soc);
                }
                usleep(100000);
                kick_kernel_battery_manager();
                battery_get_info(&bInfo);
                if (bInfo.acAttached && (bInfo.isCharging || bInfo.notChargingReason == 0)) {
                    return true;
                }
            }

            // Return hardware truth
            battery_get_info(&bInfo);
            return (bInfo.acAttached && (bInfo.isCharging || bInfo.notChargingReason == 0));
        }
    } @catch (NSException *e) { return false; }
}

bool powerui_charge_to_full_now(void) {
    return powerui_disable_hold();
}
