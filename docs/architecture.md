# Architecture

byper is two programs that share one engine.

- `byper` is a C/Obj-C CLI. It owns the power logic, the SMC reads and the bypass injection. It is installed SUID root.
- `byper.app` is a SwiftUI menu bar app. It never talks to the hardware directly. It shells out to the CLI, parses the JSON, and draws the UI.

The split keeps the privileged code small and testable from a terminal. The app can be replaced without touching the engine.

## The bypass path

macOS has no public API for "stop charging at the current level". The charging state lives in `PowerUIAgent`, a system daemon. byper attaches to it with lldb and drives its own smart-charge methods.

1. `src/powerui.m` finds `PowerUIAgent` by PID with `sysctl`.
2. It writes a small lldb script to `/tmp/byp_cmd_<pid>_<time>.lldb`. The script calls `PowerUISmartChargeManager` methods: `setOverrideAllSignals:`, `setReachedTargetSoC:`, `setMclTargetSoC:`, `engageManualChargeLimit`, and `handleNewBatteryLevel:whileExternalConnected:fullyCharged:`.
3. A forked worker runs `lldb -p <pid> --batch -s <script>` as root. The parent returns immediately.
4. The CLI polls the SMC and IOKit until the hardware reports the hold. It retries the lldb session at 1.5s, 3.5s, 6s, 10s, then every 15s, capped at 45s.
5. The hold is confirmed by the SMC mode-of-operation value (`MoO` 7) and the not-charging reason (`NCR` `0x01000000`), not by the lldb exit code.

The reverse path (`byper off`) calls `clearAllChargeLimits`, `clearManualChargeLimit`, `clearMCLOverride`, `disableMCL`, `enableCharging`, and then polls until `NCR` is 0 or the battery is charging.

Direct SMC writes to the charge-limit keys do not work on Apple Silicon. `CHBI` writes are rejected by the firmware. The lldb injection is the only path that has held up.

## The CLI

`src/main.c` is the dispatcher and the TUI. The commands are:

| Command | What it does |
|---|---|
| `byper` | Live TUI monitor |
| `byper on` | Engage bypass |
| `byper off` | Resume charging |
| `byper t` | Toggle |
| `byper s` | One-line status |
| `byper p` | Power rails |
| `byper json` | JSON snapshot |
| `byper mon` | Timestamped stream |
| `byper lpm on\|off` | Low Power Mode |
| `byper --export` | Export the session log |

`src/smc.c` is the raw AppleSMC user client. `src/battery.c` parses the IOKit power sources. `src/power.c` reads the rail telemetry.

## The app

`src/app/AppDelegate.swift` owns the status item and the popover. `BatteryMonitor.swift` is the observable state hub. `BatteryDropdownView.swift` is the popover. `CLIEngineBridge.swift` runs the CLI and decodes its JSON.

The app polls the CLI every 2s while the popover is open and every 4s in the background. The first poll is delayed by 300ms so the status item does not blink when the popover opens. Timers are added to `RunLoop.main` in `.common` mode so they keep firing while menus track the cursor or the screen sleeps.

The menu bar icon is drawn natively in `BatteryPillIcon.swift`. It is a 30 x 14 design space scaled to 12pt, with a 27 x 14 body, a D-shaped nub, and the level punched out of the pill. The drawing handler reads `NSAppearance.currentDrawing()` to decide whether the menu bar is light or dark. The status item button's `effectiveAppearance` drives the refresh when the wallpaper changes.

## Build and package

`make all` builds `bin/byper`, `bin/byper-mon.command` and `byper.app`. `./pkg/build_pkg.sh` wraps the app into `byper-installer.pkg` and `.dmg`. `BYPER_VERSION` overrides the package version.

The app bundle carries the CLI at `Contents/Resources/byper`, the installer helper, the FiraCode fonts and the app icon. The package's postinstall copies the CLI to `/usr/local/bin/byper`, sets `root:wheel` and `4755`, and installs the completions.

## Installed paths

| Path | What |
|---|---|
| `/usr/local/bin/byper` | SUID CLI |
| `/usr/local/bin/byp`, `/usr/local/bin/chbypass` | Symlinks |
| `/usr/local/bin/byper-mon.command` | Standalone monitor |
| `/usr/local/share/zsh/site-functions/_byper`, `_byp` | Zsh completions |
| `/usr/local/share/bash-completion/completions/byper`, `byp` | Bash completions |
| `/Applications/byper.app` | Menu bar app |
