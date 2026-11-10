# Handoff

This is the briefing for the next agent working on byper. Read it before touching anything. It describes the code as it stands on `main` after PR #7, not the older docs that used to live in this folder.

## What byper is

A charge-bypass tool for Apple Silicon Macs. It holds the battery at the current level and runs the machine from the charger at 0 mA net battery draw. Two programs:

- `byper`: C/Obj-C CLI, SUID root, owns the power logic.
- `byper.app`: SwiftUI menu bar app, shells out to the CLI.

## Current state

- `main` is at `1cfede4`, the merge of PR #9.
- PR #10 is open with the digit height change.
- The latest release is `v2.4.1`. Its assets were rebuilt from the stock colour and digit height changes; the tag still points to `c518a86`. Assets: `byper-installer-2.4.1.pkg`, `.dmg`, `SHA256SUMS.txt`.
- `src/app/Info.plist` still says `2.3.1`. The package version comes from `BYPER_VERSION` in `pkg/build_pkg.sh` (default `2.4.0`), so the release is 2.4.1 while the app's About version is 2.3.1. Fix this if you touch the version.
- CI: `.github/workflows/ci.yml` runs on every PR and push to `main`. Jobs: `changes` (diff filter), `checks` (shell syntax, plist, no installer artifacts, no `VANILLA`, workflow YAML, docs links), `compile` (`make all`, artifact checks, CLI smoke test).
- Build: `.github/workflows/build.yml` is manual (`workflow_dispatch`). It builds, packages, and optionally creates a release. It is not triggered by pushes.

## Repo layout

| Path | Role |
|---|---|
| `src/main.c` | CLI dispatcher, TUI, JSON, status, rails, export |
| `src/powerui.m` | PowerUIAgent lookup, lldb scripts, hold enable/disable, verify polls |
| `src/smc.c` | AppleSMC user client, key reads |
| `src/battery.c` | IOKit power-source parsing |
| `src/power.c` | Rail telemetry |
| `src/app/AppDelegate.swift` | Status item, popover, hotkey, appearance KVO, privileged install |
| `src/app/BatteryMonitor.swift` | Observable state, polling, automations, presets, logger |
| `src/app/BatteryDropdownView.swift` | Popover UI |
| `src/app/BatteryPillIcon.swift` | Native menu bar icon |
| `src/app/CLIEngineBridge.swift` | Runs the CLI, decodes JSON, LPM calls |
| `src/app/ByperIntents.swift` | App Intents (macOS 13+) |
| `src/app/install_helper.c` | Root helper for the admin-dialog install |
| `pkg/` | Package builder, preinstall, postinstall, uninstaller |
| `completions/` | Zsh and Bash completions |
| `docs/` | This folder |

## Build and test

```bash
make all                  # bin/byper, bin/byper-mon.command, byper.app
./pkg/build_pkg.sh        # byper-installer.pkg + .dmg
BYPER_VERSION=2.4.1 ./pkg/build_pkg.sh
```

There is no unit test suite. The CI compile job is the test gate: it builds, checks the artifacts, verifies the signature, and runs `./bin/byper --help`. Run the same locally before pushing.

## The bypass mechanism

`src/powerui.m` finds `PowerUIAgent` by PID with `sysctl`. It writes an lldb script to `/tmp/byp_cmd_<pid>_<time>.lldb` and forks a worker that runs `lldb -p <pid> --batch -s <script>` as root. The parent returns immediately.

The enable script calls `PowerUISmartChargeManager`:

```objc
id $m = (id)[PowerUISmartChargeManager manager];
(void)[$m setOverrideAllSignals:1];
(void)[$m setReachedTargetSoC:1];
(void)[$m setBecameOBCEligible:1];
(void)[$m setDisabledUntilDate:nil];
(void)[$m setMclTargetSoC:<soc>];
(void)[$m setSavedMCLTargetSoC:<soc>];
(void)[$m engageManualChargeLimit];
(void)[$m handleNewBatteryLevel:<soc> whileExternalConnected:1 fullyCharged:0];
```

The disable script calls `clearAllChargeLimits`, `clearManualChargeLimit`, `clearMCLOverride`, `disableMCL`, `setReachedTargetSoC:0`, `setOverrideAllSignals:0`, `setBecameOBCEligible:0`, `setDisabledUntilDate:nil`, `enableCharging`, and `handleNewBatteryLevel:whileExternalConnected:fullyCharged:`.

Both paths post `com.apple.powerui.smartchargestatuschanged` and `com.apple.powerui.mclstatuschanged`, kick the kernel battery manager, and poll the hardware. The retry curve is 1.5s, 3.5s, 6s, 10s, then every 15s, capped at 45s. The result is the hardware truth, not the lldb exit code.

Direct SMC writes to the charge-limit keys do not work on Apple Silicon. `CHBI` writes are rejected by the firmware. Do not try to replace the injection with an SMC write.

## The truth table

| State | AC | IsCharging | NCR | Amps |
|---|---|---|---|---|
| hold | attached | no | `0x01000000` | abs < 100 mA |
| charging | attached | yes | 0 | positive |
| idle / full | attached | no | 0 | abs <= 100 mA, SoC >= 95% |
| on battery | detached | no | any | negative |

Parse amperage as a signed 16/32-bit integer. Raw registry dumps can wrap negative values as unsigned two's complement.

## The app

`AppDelegate.swift` owns the status item and the popover. `BatteryMonitor.swift` is the observable state hub. `BatteryDropdownView.swift` is the popover. `CLIEngineBridge.swift` runs the CLI and decodes its JSON.

Polling:

- 2s while the popover is open.
- 4s in the background.
- 1s auto-LPM reconcile.
- The first poll is delayed by 300ms so the status item does not blink when the popover opens.
- Timers are added to `RunLoop.main` in `.common` mode so they keep firing while menus track the cursor or the screen sleeps.

The popover is 244pt wide and locked to `darkAqua`. On macOS 13+ the hosting controller uses `NSHostingSizingOptions.preferredContentSize`. Every expandable flag must still be in the `Publishers.Merge` in `applicationDidFinishLaunching` for the older path.

The global hotkey is Cmd+Opt+B. App Intents expose bypass on, off and toggle on macOS 13+.

## The menu bar icon

`BatteryPillIcon.swift` draws the icon natively. No PNGs.

- Design space 30 x 14, default height 12pt.
- Body 27 x 14, corner radius 4.2.
- Nub: x 28.3 to 29.9, y 4.65 to 9.35, right corners r0.8, flat left.
- Digit ink height 8.4, font size about 11.92, centred on the ink bounding box.
- Fill width `round(27 * level / 100)`.
- Track opacity 0.44 for the idle pill, 0.20 for the coloured pills. Nub opacity 0.55.
- Base ink black at 0.93 alpha, paper white at 0.93 alpha.
- Mode colours: charging `#30D158`, bypass `#DC8038`, low power `#FFD60A`, low battery `#FF453A`.
- The track and nub use the menu bar ink, not the mode colour.
- The number uses the menu bar text colour: black on a light bar, white on a dark one. The idle pill is the exception, where the number is a knockout.
- The drawing handler reads `NSAppearance.currentDrawing()` to decide light or dark.
- `AppDelegate` observes `button.effectiveAppearance`, filters to `.vibrantDark` and `.vibrantLight`, and calls `refreshIcon()` when the value changes. That is the wallpaper signal. `NSApp.effectiveAppearance` follows the system mode, not the menu bar, so do not use it.

## Live features

- Bypass toggle, with "Off on exit".
- Powersave (Low Power Mode), manual plus per-app auto-LPM.
- Caffeinate, manual plus "On Bypass".
- Settings: Auto Bypass on Connect, at Login, on Display; Logger; Export; Presets Travel and Docked.
- The master slider on the left is a continuous level. It fades and disables the rows as it descends. Full-off snapshots the state, full-on restores it.
- The logger writes `byper-session-<timestamp>.csv` to the Desktop.
- Global hotkey Cmd+Opt+B.
- App Intents for bypass on, off and toggle.

## Disabled features

Do not document these as live:

- **Threshold.** `checkAutoBypassThreshold()` disables the flag on launch. The trigger only engaged while freshly toggled and had reliability issues.
- **Slow Charge.** The `slowChargeEnabled` setter forces the flag off. The duty cycle could re-engage bypass after a while.

## Hard constraints

- SUID is load-bearing. A non-SUID CLI prints `enabled [✓]` and does nothing. After any reinstall or copy, re-apply `chown root:wheel` and `chmod 4755`.
- Never write SMC charge keys. They are read-only on Apple Silicon.
- Never signal `powerd`.
- Never persist an MCL below 100.
- No em dashes or en dashes in docs, comments, commits or UI strings.
- No "Generated by Mistral Vibe" trailer in commits.
- Commit format is `type: description`, no scope. Never `feat(xxx):`.
- Workflow: fix, give the installer, wait for feedback, then open a PR, then the user merges.
- The Build workflow stays manual. CI is a test gate, not an auto-build.
- No emoji in UI or CLI output.

## Known issues

- `src/app/Info.plist` says `2.3.1` while the package is `2.4.1`.
- `pkg/postinstall` still mentions "vanilla branch" and `byper-vanilla.app`. It is legacy cleanup. Do not reintroduce the vanilla variant.
- `install.sh` prints `byper stream` and `byper json --watch`. Neither command exists. The real ones are `byper mon` and `byper json`.
- `pkg/Distribution.xml` has a hardcoded `2.3.1` title. `build_pkg.sh` replaces it with `TITLE`. Do not edit the title by hand.
- `uninstall.sh` only removes files. It does not release a hold or clear LPM. The package uninstaller does.
- `runPrivilegedInstall` in `AppDelegate.swift` has hardcoded project paths under `/Users/gefaass`.
- `src/main.c` falls back to `/Users/gefaass` for the Desktop export path.
- The stock menu bar battery can lag the app by one level in screenshots. Check the stock digits before comparing.
- The status item button's `effectiveAppearance` fires a storm of `Aqua`, `DarkAqua` and `Vibrant*` values on click. The KVO filters to the vibrant pair and guards against repeats, so it does not re-render on click.
- `NSAppearance.current` is deprecated. Use `NSAppearance.currentDrawing()`.
- `NSAppearance.currentDrawingAppearance` is renamed to `currentDrawing()` in this SDK.
- `NSWorkspace.desktopImageDidChangeNotification` does not exist in this SDK. The wallpaper signal is the button's `effectiveAppearance`.

## Where to look

- Bypass not landing: `src/powerui.m`, `spawn_hold_enable_script`, `powerui_enable_hold`.
- CLI JSON fields: `src/main.c`, `print_status`.
- App polling: `BatteryMonitor.startActivePolling`, `startBackgroundPolling`.
- Menu bar icon: `BatteryPillIcon.swift`.
- Popover layout: `BatteryDropdownView.swift`.
- Package: `pkg/build_pkg.sh`, `pkg/preinstall`, `pkg/postinstall`, `pkg/uninstall-postinstall`.
- CI: `.github/workflows/ci.yml`.
- Build and release: `.github/workflows/build.yml`.
