# Architecture

byper is two deliverables around one engine: a SUID-root C/ObjC CLI (`byper`) and a SwiftUI menu bar app (`byper.app`) that shells out to that CLI rather than duplicating any power logic.

```
┌────────────────────────┐        ┌──────────────────────────┐
│  byper.app (SwiftUI)   │ exec   │  byper CLI (C/ObjC)      │
│  menu bar, popover,    │───────▶│  SUID root, arm64        │
│  automations, presets  │ stdout │                          │
└───────────┬────────────┘        └───────────┬──────────────┘
            │ IOKit.ps (event-driven)         │
            ▼                                 ▼
   Battery telemetry                   ┌──────────────┐
   (percentage, flow,                  │  SMC keys    │
    AC state, rails)                   └──────┬───────┘
                                              │ read
                                       PMG / SMC hardware
                                              ▲
                                       write via injection
                                       into PowerUIAgent
```

## Components

| File | Role |
|---|---|
| `src/main.c` | CLI entry, interactive TUI monitor, JSON/telemetry output, command routing (~1650 lines) |
| `src/powerui.m` | The bypass engine: finds `PowerUIAgent`, forks a fire-and-forget worker that drives `lldb` in batch mode against it (see below) |
| `src/smc.c/h` | Raw AppleSMC IOKit user client: key info, byte reads/writes, typed decoders |
| `src/battery.c/h` | IOKit power-source parsing: SoC, flow, adapter data, cell voltages |
| `src/power.c/h` | Power-rails telemetry (SoC/DRAM/PMIC/DC-in wattage) via SMC + IOKit |
| `src/app/AppDelegate.swift` | Status item, popover lifecycle, auto-refit wiring, self-updater |
| `src/app/BatteryMonitor.swift` | `ObservableObject` telemetry hub, automations, Slow Charge state machine, threshold logic (~1770 lines) |
| `src/app/BatteryDropdownView.swift` | The popover UI (replaces the stock battery menu extra) |
| `src/app/CLIEngineBridge.swift` | Shells out to the CLI, parses NDJSON; manages `pmset` LPM calls |
| `src/app/ByperIntents.swift` | App Intents / Shortcuts (macOS 13+) |
| `src/app/install_helper.c` | Tiny root helper that fixes SUID ownership, run via the admin dialog |

## The bypass mechanism

macOS has no public API for "stop charging at the current level." Every surfaced knob (Optimized Charging, charge limits via `pmset`) is managed by **PowerUIAgent**, a system daemon whose in-memory charging state is not persisted or externally controllable. byper therefore:

1. Locates `PowerUIAgent` by PID (sysctl `KERN_PROC_ALL`, no subprocess).
2. Writes a tiny lldb batch script to `/tmp` (flock-serialized at `/tmp/byp_lldb.lock`).
3. Forks an orphaned worker that runs `lldb -p <pid> --batch -s <script>` as **root** (SUID install → direct attach; dev builds fall back to `sudo -S`), calls the daemon's own smart-charge entry points to enter *Not Charging / hold* mode, then detaches. The parent returns immediately. The multi-second attach happens in the background, and the UI's verify-poll gates truth (engine fields can lag ~45 s behind a tap).
4. Hardware truth is confirmed by polling SMC registers, never by trusting the injection result.

The actual charge inhibition is the SMC **mode-of-operation** value (MoO: 1 = charging, 7 = hold). The daemon sets it, and the CLI reads the truth table back from the SMC. Direct SMC writes to charge-limit keys (e.g. `CHBI`) were tested and are **rejected by the firmware**, which is why injection is the load-bearing path.

### Dev-path authentication

The dev-path fallback (`sudo -S lldb`) for non-root builds reads the sudo password from the `BYP_SUDO_PASS` environment variable, set by the developer in their own shell. **No credential is embedded in the repository:**

- SUID install path: root attaches directly, `sudo -S` unused.
- Dev path (non-root build): export `BYP_SUDO_PASS` in your shell before running dev builds (or just run them via `sudo`).
- PKG installs never touch it (they use the admin-dialog helper + SUID).

The repository is therefore safe to publish; the credential-scrub history rewrite (2.2.0) was verified and force-pushed.

## State machines worth knowing

### Bypass ⇄ Slow Charge exclusivity

These two features are mutually exclusive at four layers (model, gesture, bridge, engine): engaging one refuses or tears down the other. Both custom `ToggleStyle`s use raw gestures that ignore `.disabled`, which is why enforcement is duplicated at the model level. Auto-engage paths for bypass (plug, login, display, threshold) all yield while Slow Charge is enabled.

### Slow Charge duty cycle

Trickles the battery by holding (MoO 7) for 20 s, releasing for a 40 s charge burst, repeating until the target SoC. Keyed off `appliedPowerMode` (hardware truth), not the UI's requested state. Runs with a `beginActivity` assertion because App Nap suspends `Timer.scheduledTimer` timers when the screen sleeps. That was the original threshold-miss bug.

### Threshold automation

Engages hold when SoC ≤ threshold; a manual resume snoozes it until the battery climbs back above the threshold. Polls and timers run in `.common` run-loop mode so they survive open menus and display sleep.

### Launch reseed

On launch the app clears stale holds when Slow Charge is enabled (a previous session's bypass can otherwise deadlock the duty cycle), and quit disables effects while relaunch restores the prior setup.

## Build targets

`make` produces:

- `bin/byper`: clang, `-O3`, ObjC ARC, arm64 macOS 11.0+, ad-hoc codesigned.
- `byper.app`: `swiftc -whole-module-optimization`, bundles the CLI at `Contents/Resources/byper` (SUID), the installer helper, FiraCode fonts, and high-DPI battery icons.
- `byper-mon.command`: standalone monitor droplet.

`pkg/build_pkg.sh` then wraps the app into `byper-installer.pkg` (productbuild; `pkg/preinstall` is the upgrade path and keeps settings, while the Uninstall choice's `pkg/uninstall-postinstall` is a complete uninstaller; the postinstall enables DevToolsSecurity and `_developer` membership so lldb can attach).

`install.sh` builds **as the invoking user** even when sudo'd (root-owned build artifacts are the #1 cause of later `ld: can't write output file` failures), then installs the CLI SUID root: `chown root:wheel`, `chmod 4755`. The SUID bit is load-bearing. A non-SUID CLI prints `enabled [✓]` while the hardware write silently fails.
