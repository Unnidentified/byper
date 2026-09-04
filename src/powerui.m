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
#import <spawn.h>
#import <sys/wait.h>
#import <sys/sysctl.h>

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

// Run LLDB script via posix_spawn — no intermediate shell fork needed
static void run_lldb_script(const char *script_path) {
    pid_t agent_pid = find_powerui_pid();
    if (agent_pid == 0) {
        char cmd[512];
        snprintf(cmd, sizeof(cmd),
            "echo \"REDACTED\" | sudo -S lldb -p $(pgrep -x PowerUIAgent) --batch -s %s >/dev/null 2>&1",
            script_path);
        system(cmd);
        return;
    }

    char pid_str[16];
    snprintf(pid_str, sizeof(pid_str), "%d", agent_pid);

    const char *lldb_argv[] = {
        "/usr/bin/sudo", "-S",
        "/usr/bin/lldb", "-p", pid_str,
        "--batch", "-s", script_path,
        NULL
    };

    int pipefd[2];
    pipe(pipefd);
    write(pipefd[1], "REDACTED\n", 10);
    close(pipefd[1]);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[0], STDIN_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    posix_spawn_file_actions_adddup2(&actions, devnull, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, devnull, STDERR_FILENO);

    pid_t child;
    if (posix_spawn(&child, "/usr/bin/sudo", &actions, NULL, (char *const *)lldb_argv, environ) == 0) {
        int status;
        waitpid(child, &status, 0);
    }

    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[0]);
    close(devnull);
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
            FILE *fp = fopen("/tmp/byp_cmd.lldb", "w");
            if (fp) {
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
                fclose(fp);
                run_lldb_script("/tmp/byp_cmd.lldb");
                unlink("/tmp/byp_cmd.lldb");
            }

            // 3. Notify subsystems & kick kernel driver
            notify_post("com.apple.powerui.smartchargestatuschanged");
            notify_post("com.apple.powerui.mclstatuschanged");
            kick_kernel_battery_manager();

            // 4. Live hardware verification poll (~2.4s max, 80ms intervals)
            for (int i = 0; i < 30; i++) {
                usleep(80000); // 80ms — SMC updates fast once LLDB commits
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
            FILE *fp = fopen("/tmp/byp_cmd.lldb", "w");
            if (fp) {
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
                fclose(fp);
                run_lldb_script("/tmp/byp_cmd.lldb");
                unlink("/tmp/byp_cmd.lldb");
            }

            // 2. Trigger immediate resume kick via LLDB (handled above)

            // 3. Clean up saved defaults overrides — single PlistBuddy call instead of 5 serial forks
            system("/usr/libexec/PlistBuddy -c 'Delete :overrideDesktopMode' -c 'Delete :isDesktopModeDevice' -c 'Delete :chargeTokenMCL' -c 'Delete :chargeTokenDEoC' -c 'Delete :reachedTargetSoC' /Library/Preferences/com.apple.PowerUI.plist > /dev/null 2>&1 || true");

            // 4. Notify subsystems & kick kernel driver
            notify_post("com.apple.powerui.smartchargestatuschanged");
            notify_post("com.apple.powerui.mclstatuschanged");
            kick_kernel_battery_manager();

            // 5. Live hardware verification poll (~2.4s max, 80ms intervals)
            for (int i = 0; i < 30; i++) {
                usleep(80000); // 80ms
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
