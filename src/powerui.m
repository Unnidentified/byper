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
#import <string.h>
#import <libproc.h>

// Minimal, attacker-independent environment for every privileged child. The
// invoking user's PATH, HOME, DYLD_* and LLDB_* must never reach a root child:
// lldb sources $HOME/.lldbinit at startup, and a shell resolves tools from
// PATH. Children get this fixed environment instead of the inherited one.
static char *const g_child_env[] = {
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME=/var/root",
    "TMPDIR=/tmp",
    "LANG=C",
    NULL
};

// Run a fixed argv with the sanitized environment, capturing stdout into out.
// No shell is involved, so neither PATH nor a command string can be influenced
// by the caller. Returns the exit status, or -1 on spawn failure.
static int spawn_capture(char *const argv[], char *out, size_t outsz) {
    if (out && outsz) out[0] = '\0';
    int pipefd[2];
    if (pipe(pipefd) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDERR_FILENO); if (dn > STDERR_FILENO) close(dn); }
        close(pipefd[1]);
        execve(argv[0], argv, g_child_env);
        _exit(127);
    }
    close(pipefd[1]);
    if (out && outsz) {
        size_t used = 0;
        ssize_t n;
        while (used + 1 < outsz && (n = read(pipefd[0], out + used, outsz - 1 - used)) > 0) {
            used += (size_t)n;
        }
        out[used] = '\0';
    }
    close(pipefd[0]);
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

// Fire-and-forget spawn with the sanitized environment and detached stdio, so
// a long-running child (softwareupdate) cannot hold the caller's stdout pipe
// open. The child is orphaned to launchd when the CLI exits.
static void spawn_detached(char *const argv[]) {
    pid_t pid = fork();
    if (pid != 0) return;
    setsid();
    int dn = open("/dev/null", O_RDWR);
    if (dn >= 0) {
        dup2(dn, STDIN_FILENO);
        dup2(dn, STDOUT_FILENO);
        dup2(dn, STDERR_FILENO);
        if (dn > STDERR_FILENO) close(dn);
    }
    execve(argv[0], argv, g_child_env);
    _exit(127);
}

// Find PowerUIAgent PID via sysctl, no subprocess spawn needed. The name alone
// is spoofable (any user can run a binary called PowerUIAgent and have root
// lldb attach to it), so also require the executable to live in a trusted
// system location.
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
        if (strcmp(procs[i].kp_proc.p_comm, "PowerUIAgent") != 0) continue;
        pid_t pid = procs[i].kp_proc.p_pid;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) continue;
        const char *base = strrchr(path, '/');
        if (!base || strcmp(base + 1, "PowerUIAgent") != 0) continue;
        if (strncmp(path, "/usr/libexec/", 13) != 0 && strncmp(path, "/System/", 8) != 0) continue;
        found = pid;
        break;
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

// Run LLDB script, fire-and-forget with a detached worker: the CLI no longer
// blocks on the full lldb lifecycle (attach + symbol load + detach), whose
// occasional latency spikes were the rare toggle hang. The expr commits as
// soon as lldb evaluates it, so the caller's hardware verify poll
// (powerui_enable_hold / powerui_disable_hold) remains the sole success gate
// and still blocks until state is confirmed or its budget is exhausted.
//
// Serialization: two debuggers cannot hold PowerUIAgent's debug port at once,
// so sessions serialize on an flock'ed lock file shared across processes (each
// byper invocation is a fresh process). Acquisition is bounded at 3 s, on
// contention timeout this round skips (unlink script, return) instead of
// stacking a doomed attach.
//
// The worker is a forked child that spawns lldb as ITS child, reaps it, unlinks
// the script, and releases the lock. This process returns immediately and
// exits seconds later, so the worker is orphaned to launchd, no zombies, and
// cleanup survives the CLI's early exit.
#define BYP_LLDB_LOCK_PATH "/tmp/byp_lldb.lock"

// Ensure a working lldb exists. On a fresh Mac the Command Line Tools are absent
// and /usr/bin/lldb is either missing or a stub that pops a GUI dialog. As root
// (SUID install) we can install the tools silently via softwareupdate, the
// first toggle just takes a few minutes while they download.
static bool ensure_lldb_available(void) {
    // Accept ANY working toolchain: the CLT path, or whatever xcode-select
    // points at (full Xcode installs have no /Library/Developer/CommandLineTools
    // but a perfectly good lldb, the old CLT-only check locked those out).
    char cand[640];
    snprintf(cand, sizeof(cand), "/Library/Developer/CommandLineTools/usr/bin/lldb");
    if (access(cand, X_OK) == 0) return true;

    // Absolute path + sanitized env: the old popen("xcode-select -p") resolved
    // the tool through the caller's PATH, which a SUID run inherits from an
    // unprivileged user (root code execution via a planted xcode-select).
    char xcodepath[512] = {0};
    char *const xp_argv[] = { "/usr/bin/xcode-select", "-p", NULL };
    if (spawn_capture(xp_argv, xcodepath, sizeof(xcodepath)) == 0) {
        size_t n = strlen(xcodepath);
        while (n > 0 && (xcodepath[n-1] == '\n' || xcodepath[n-1] == '\r' || xcodepath[n-1] == ' ')) xcodepath[--n] = '\0';
        snprintf(cand, sizeof(cand), "%s/usr/bin/lldb", xcodepath);
        if (access(cand, X_OK) == 0) return true;
    }

    if (geteuid() != 0) return false; // can't self-install unprivileged

    // The label pipeline is a fixed literal with absolute tool paths, run under
    // the sanitized environment, so it cannot be hijacked via PATH. The label
    // is then passed to softwareupdate as an argv element, never interpolated
    // into a shell string (the old system() interpolated it between quotes).
    char label[256] = {0};
    char *const list_argv[] = { "/bin/sh", "-c",
        "/usr/bin/softwareupdate --list 2>/dev/null | /usr/bin/awk -F'\\\\*' '/Command Line Tools/{print $1}' | /usr/bin/sed 's/^[[:space:]]*//' | /usr/bin/head -1",
        NULL };
    spawn_capture(list_argv, label, sizeof(label));
    size_t n = strlen(label);
    while (n > 0 && (label[n-1] == '\n' || label[n-1] == '\r' || label[n-1] == ' ')) label[--n] = '\0';
    if (label[0] == '\0') return false;

    char *const inst_argv[] = { "/usr/bin/softwareupdate", "--install", label, "--no-scan", NULL };
    spawn_detached(inst_argv);
    return false; // installing asynchronously; this round fails, the next works
}

// Blocking inline fallback (used only when fork fails): spawn lldb as our own
// child and wait for it, the pre-fix behavior, kept for robustness.
static void posix_spawn_and_wait(pid_t agent_pid, int stdin_fd, const char *script_path) {
    char pid_str[16];
    snprintf(pid_str, sizeof(pid_str), "%d", agent_pid);
    // Root (SUID install) attaches directly; sudo -S is the non-root dev path.
    bool as_root = (geteuid() == 0);
    const char *argv_root[] = {
        "/usr/bin/lldb", "--no-lldbinit", "-p", pid_str,
        "--batch", "-s", script_path,
        NULL
    };
    const char *argv_sudo[] = {
        "/usr/bin/sudo", "-S",
        "/usr/bin/lldb", "--no-lldbinit", "-p", pid_str,
        "--batch", "-s", script_path,
        NULL
    };
    const char *exec_path = as_root ? argv_root[0] : argv_sudo[0];
    const char *const *lldb_argv = as_root ? (const char *const *)argv_root : (const char *const *)argv_sudo;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, stdin_fd, STDIN_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    posix_spawn_file_actions_adddup2(&actions, devnull, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, devnull, STDERR_FILENO);

    pid_t child;
    if (posix_spawn(&child, exec_path, &actions, NULL, (char *const *)lldb_argv, g_child_env) == 0) {
        int st;
        while (waitpid(child, &st, 0) < 0 && errno == EINTR) {}
    }
    posix_spawn_file_actions_destroy(&actions);
    close(devnull);
}

static void run_lldb_script(const char *script_path) {
    if (!ensure_lldb_available()) {
        unlink(script_path); // no lldb (install kicked off); verify poll reports truth
        return;
    }
    int lock_fd = open(BYP_LLDB_LOCK_PATH, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    bool locked = false;
    if (lock_fd >= 0) {
        fchmod(lock_fd, 0666); // let non-root dev builds contend a root-made lock
        for (int i = 0; i < 1600; i++) { // ≤ 32 s: must cover the worker's 30 s
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

    // Prepare a stdin pipe for the lldb worker BEFORE the fork so both the
    // worker and the fork-failure fallback can hand lldb a ready stdin.
    // No credential is embedded in the source: for the non-root dev path the
    // password is taken from the BYP_SUDO_PASS environment variable (set it
    // in your shell only); SUID/root installs never use it.
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        close(lock_fd);
        unlink(script_path);
        return;
    }
    const char *env_pw = getenv("BYP_SUDO_PASS");
    if (env_pw && *env_pw) {
        ssize_t pw = write(pipefd[1], env_pw, strlen(env_pw));
        (void)pw;
        ssize_t nl = write(pipefd[1], "\n", 1);
        (void)nl;
    }
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
    // block until this worker exits, silently undoing the fire-and-forget.
    int dn = open("/dev/null", O_RDWR);
    if (dn >= 0) {
        dup2(dn, STDIN_FILENO);
        dup2(dn, STDOUT_FILENO);
        dup2(dn, STDERR_FILENO);
        if (dn > STDERR_FILENO) close(dn);
    }

    char pid_str[16];
    snprintf(pid_str, sizeof(pid_str), "%d", agent_pid);
    // Root (SUID install) attaches directly, no sudo, no password. The sudo -S
    // path is only for non-root dev builds.
    bool as_root = (geteuid() == 0);
    const char *argv_root[] = {
        "/usr/bin/lldb", "--no-lldbinit", "-p", pid_str,
        "--batch", "-s", script_path,
        NULL
    };
    const char *argv_sudo[] = {
        "/usr/bin/sudo", "-S",
        "/usr/bin/lldb", "--no-lldbinit", "-p", pid_str,
        "--batch", "-s", script_path,
        NULL
    };
    const char *exec_path = as_root ? argv_root[0] : argv_sudo[0];
    const char *const *lldb_argv = as_root ? (const char *const *)argv_root : (const char *const *)argv_sudo;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[0], STDIN_FILENO);
    // Remote diagnostics: BYP_LLDB_DEBUG=1 sends the session transcript to a log
    // instead of the void, run `BYP_LLDB_DEBUG=1 byper on` on a failing machine
    // and read /tmp/byp_lldb_debug.log.
    int devnull = getenv("BYP_LLDB_DEBUG")
        ? open("/tmp/byp_lldb_debug.log", O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600)
        : open("/dev/null", O_WRONLY);
    posix_spawn_file_actions_adddup2(&actions, devnull, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, devnull, STDERR_FILENO);

    pid_t child;
    if (posix_spawn(&child, exec_path, &actions, NULL, (char *const *)lldb_argv, g_child_env) == 0) {
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
//  LLDB SCRIPT HELPERS: one session per spawn; re-spawned on verify failure
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
//  ENABLE HOLD: Charging On Hold at current SoC (Runtime In-Memory Hold)
// ─────────────────────────────────────────────────────────────────────────────
bool powerui_enable_hold(void) {
    @try {
        @autoreleasepool {
            BatteryInfo bInfo;
            battery_get_info(&bInfo);
            if (!bInfo.acAttached) {
                return false;
            }
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
            // re-spawn a fresh LLDB session, a later session provably lands it.
            for (int i = 0; i < 450; i++) {
                if (i > 0 && (i == 15 || i == 35 || i == 60 || i == 100 || (i % 150) == 0)) {
                    battery_get_info(&bInfo);
                    spawn_hold_enable_script(bInfo.percentage > 0 && bInfo.percentage <= 100 ? bInfo.percentage : soc);
                }
                usleep(100000);
                kick_kernel_battery_manager();
                battery_get_info(&bInfo);
                // At full battery the hold flag never sets (idle/full is already
                // the goal state: wall runs the laptop, battery resting).
                bool isHold = (bInfo.acAttached && !bInfo.isCharging &&
                               abs(bInfo.amperage) < 100 &&
                               (((bInfo.notChargingReason & 0x01000000) != 0) ||
                                bInfo.percentage >= 95));
                if (isHold) return true;
            }

            // Return hardware truth
            battery_get_info(&bInfo);
            return (bInfo.acAttached && !bInfo.isCharging && abs(bInfo.amperage) < 100 &&
                    (((bInfo.notChargingReason & 0x01000000) != 0) || bInfo.percentage >= 95));
        }
    } @catch (NSException *e) { return false; }
}

// ─────────────────────────────────────────────────────────────────────────────
//  DISABLE HOLD: Resume full fast charging to 100%
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

            // 3. Clean up saved defaults overrides. Fixed argv, no shell: the
            // old system() string ran through /bin/sh in a SUID process.
            char *const pb_argv[] = {
                "/usr/libexec/PlistBuddy",
                "-c", "Delete :overrideDesktopMode",
                "-c", "Delete :isDesktopModeDevice",
                "-c", "Delete :chargeTokenMCL",
                "-c", "Delete :chargeTokenDEoC",
                "-c", "Delete :reachedTargetSoC",
                "/Library/Preferences/com.apple.PowerUI.plist",
                NULL
            };
            (void)spawn_capture(pb_argv, NULL, 0); // best effort, like the old "|| true"

            // 4. Notify subsystems & kick kernel driver
            notify_post("com.apple.powerui.smartchargestatuschanged");
            notify_post("com.apple.powerui.mclstatuschanged");
            kick_kernel_battery_manager();

            // If not connected to AC power, battery is discharging and cannot
            // charge or hold, reset is already complete; return immediately.
            if (!bInfo.acAttached) {
                return true;
            }

            // 5. Live hardware verification poll (≤45s, 100ms intervals). If the
            // target state hasn't arrived after ~10s (observed: PowerUIAgent's
            // state machine transiently swallows the resume right after an
            // engage), re-spawn a fresh LLDB session, a later session lands it.
            for (int i = 0; i < 450; i++) {
                if (i > 0 && (i == 15 || i == 35 || i == 60 || i == 100 || (i % 150) == 0)) {
                    battery_get_info(&bInfo);
                    spawn_hold_disable_script(bInfo.percentage > 0 && bInfo.percentage <= 100 ? bInfo.percentage : soc);
                }
                usleep(100000);
                kick_kernel_battery_manager();
                battery_get_info(&bInfo);
                if (!bInfo.acAttached || bInfo.isCharging || bInfo.notChargingReason == 0) {
                    return true;
                }
            }

            // Return hardware truth
            battery_get_info(&bInfo);
            return (!bInfo.acAttached || bInfo.isCharging || bInfo.notChargingReason == 0);
        }
    } @catch (NSException *e) { return false; }
}

bool powerui_charge_to_full_now(void) {
    return powerui_disable_hold();
}
