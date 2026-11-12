# Architecture

byper is two programs that share one engine.

- `byper` is a C and Objective-C CLI. It owns the power logic, the SMC reads and
  the bypass injection. It is installed SUID root.
- `byper.app` is a SwiftUI menu bar app. It shells out to the CLI and parses
  the JSON for the power logic, and reads `AppleSmartBattery` from IOKit in
  process for the fast path that keeps the menu bar pill current.

The split keeps the privileged code small and testable from a terminal. The app
can be replaced without touching the engine.

## The bypass path

macOS has no public API for "stop charging at the current level". The charging
state lives in `PowerUIAgent`, a system daemon. byper attaches to it with lldb
and drives its own smart-charge methods.

1. `src/powerui.m` finds `PowerUIAgent` by PID with `sysctl`.
2. It writes a small lldb script to `/tmp/byp_cmd_<pid>_<time>.lldb`. The script
   calls `PowerUISmartChargeManager` methods: `setOverrideAllSignals:`,
   `setReachedTargetSoC:`, `setMclTargetSoC:`, `engageManualChargeLimit`, and
   `handleNewBatteryLevel:whileExternalConnected:fullyCharged:`.
3. A forked worker runs `lldb -p <pid> --batch -s <script>` as root. The parent
   returns immediately.
4. The CLI polls the SMC and IOKit until the hardware reports the hold. It
   retries the lldb session at 1.5s, 3.5s, 6s, 10s, then every 15s, capped at
   45s.
5. The hold is confirmed by the not-charging reason (`NCR` `0x01000000`) and a
   near-zero amperage, not by the lldb exit code.

The reverse path (`byper off`) calls `clearAllChargeLimits`,
`clearManualChargeLimit`, `clearMCLOverride`, `disableMCL`, `enableCharging`,
and then polls until `NCR` is 0 or the battery is charging.

Direct SMC writes to the charge-limit keys do not work on Apple Silicon. `CHBI`
writes are rejected by the firmware. The lldb injection is the only path that
has held up.

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
| `byper mon` | Timestamped stream, `--export` writes the log |
| `byper lpm on\|off` | Low Power Mode |
| `byper caffeinate on\|off` | Hold the display and idle sleep |
| `byper caffeinate auto on\|off` | Hold them only while a bypass hold is active |
| `byper caffeinate status` | Caffeinate state and the keys behind it |
| `byper lid on\|off` | Disable or restore system sleep, the switch behind the lid condition |
| `byper lid status` | The lid sleep switch and who owns it |
| `byper logger [--quiet]` | Continuous CSV session log on the Desktop |
| `byper auto` | Automation settings and the runner state |
| `byper auto run [--quiet] [--force]` | Run the automations until interrupted |
| `byper auto plug\|login\|display\|off-on-exit on\|off` | Toggle one automation |
| `byper auto lpm add\|remove\|list\|clear [bundle-id]` | Per app Low Power Mode |
| `byper help` | Usage |

`src/smc.c` is the raw AppleSMC user client. `src/battery.c` parses the IOKit
power sources. `src/power.c` reads the rail telemetry. `src/prefs.c` owns the
shared settings domain, `src/session.c` writes the CSV session log and
`src/automation.c` holds the platform probes, caffeinate and the automation
runner.

### Shared settings

The CLI and the app read and write one settings domain, `com.gefaass.byper`, in
`~/Library/Preferences`. There is no second config file and no second set of key
names. `src/prefs.c` reads through `CFPreferences` and writes through
`/usr/bin/defaults` as the settings owner, so a change made in either program is
visible to the other.

The settings owner is resolved once, in `prefs_resolve`: `SUDO_USER` first, then
the uid that invoked the binary, then the console user, then root. The console
step is what makes a root process with no `SUDO_USER` (a package script,
`sudo env -u SUDO_USER`, a launchd job) read the same domain the app and the
user's own CLI run read. Without it a privileged path falls back to root's empty
domain, every read returns its fallback, and the caller silently does nothing.

| Key | Type | Meaning |
|---|---|---|
| `byp_auto_caffeine_on_bypass` | bool | Hold the display and idle sleep while a bypass hold is active |
| `byp_auto_hold_at_login` | bool | Engage bypass when the automation runner starts |
| `byp_auto_hold_on_display` | bool, default true | Engage bypass when an external display attaches |
| `byp_auto_hold_on_plug` | bool | Engage bypass when the charger connects |
| `byp_auto_lpm_bundle_ids` | array of strings | Low Power Mode while one of these apps is frontmost |
| `byp_cached_installed_apps` | array of dicts | The app's cache of installed apps. The CLI only reads it |
| `byp_caffeine_always_on` | bool | Manual caffeinate |
| `byp_disable_bypass_on_quit` | bool | Release the bypass hold when the automation runner exits |
| `byp_lid_sleep_owned` | bool | byper set `SleepDisabled` and must clear it again |
| `byp_master_level` | double 0 to 1 | The app's master slider. The CLI stands down below 0.999 |
| `byp_power_mode` | string | `bypass` or `charging`, written by `on`, `off` and `t` |
| `byp_resume_bypass_on_launch` | bool | The app's quit handoff. The CLI neither reads nor writes it |

The CLI reads the keys on every tick, so a change made in the app is picked up
without a restart. The app seeds its properties from the same keys at launch, so
a change made in the CLI reaches the app at its next launch.

### Automations

A one shot command cannot notice a charger connect or a display attach, so the
automations run in a foreground process:

```bash
byper auto run
```

It polls every 2s, re-reads the settings each tick, and drives the same engine
the one shot verbs use. It refuses to start while `byper.app` is running,
because the app already drives the same automations, and it takes a lock so two
runners cannot overlap. There is no LaunchAgent: the app registers its own login
item for `byp_auto_hold_at_login`, and a second always on driver would race it.
A CLI only user adds `byper auto run` to Login Items.

The runner also reconciles caffeinate (manual or on bypass) and per app Low
Power Mode. It only turns Low Power Mode back off when it was the process that
turned it on, so a manual `byper lpm on` survives.

### The lid switch

The idle-sleep assertions do not survive a lid close. `pmset -g log` records the
sleep as `Clamshell Sleep`, and it happens with `PreventUserIdleSystemSleep` and
`PreventUserIdleDisplaySleep` both held. The only switch that overrides it is
`SleepDisabled`, which `pmset -a disablesleep` writes and which needs root.

`byper lid on` sets it, `byper lid off` clears it and `byper lid status` reports
it. The flag is held while `byp_auto_caffeine_on_lid_close` is armed, not only
while the lid is closed: powerd reads `isSleepDisabled` at the clamshell event
and commits to the sleep there, so a flag set after the lid shuts is too late.

`SleepDisabled` is a stored system setting, not an assertion. It is not owned by
a process, so killing the process that set it leaves it set. `byp_lid_sleep_owned`
records that byper was the one that set it, so a disarm, a quit, the next launch
or either uninstall path clears it, and a flag the user set themselves is left
alone.

The automation runner does not touch the switch. It follows the armed key, and
the app plus the explicit `byper lid` and `byper caffeinate lid` commands are
what write it, so a runner that exits cannot strand the machine unable to sleep.

### The session logger

`byper logger` writes `byper-session-<yyyyMMdd-HHmmss>.csv` to the Desktop of
the user whose settings are shared, one row per second, flushed as it goes. The
file name, the header and the columns match the app's export. When the CLI runs
through the SUID path the Desktop belongs to the invoking user, not to root, so
the file is created there and chowned to that user.

## The app

`src/app/AppDelegate.swift` owns the status item and the popover lifecycle.
`BatteryMonitor.swift` is the observable state hub. `BatteryDropdownView.swift`
is the popover content. `CLIEngineBridge.swift` runs the CLI and decodes its
JSON.

The app polls the CLI every 2s while the popover is open. In the background a
4s timer runs an IOKit read only, with no CLI subprocess. The first poll is
delayed by 300ms so the status item does not blink when the popover opens.
Timers are added to `RunLoop.main` in `.common` mode so they keep firing while
menus track the cursor or the screen sleeps.

### The popover chrome

`GlassPopover.swift` holds the popover chrome. On macOS 26 and later the shell
and its notch are one continuous Liquid Glass shape, drawn by
`NotchedRoundedRect` and hosted in a borderless non-activating `NSPanel`
anchored under the status item. The notch is spliced into the same path as the
body, so the two read as one piece. The inner card is opaque
and sits on the glass as a sunken panel. Reduce Transparency, or an older
system, falls back to the previous dark solid shell.

The panel sets `hasShadow = false`. AppKit derives the window shadow from the
alpha channel, and a partly transparent shell makes it fall back to a
rectangular mask, which paints a hard square behind the rounded corners.
`invalidateShadow()` does not correct it, so the glass supplies its own depth.

`PopoverPanelController` runs a four state machine (`closed`, `opening`, `open`,
`closing`) so one click produces one transition. It installs the event monitors
on open and removes them on close, and it owns the status item highlight pill.

Every tunable lives in `PopoverTuning` in `GlassPopover.swift`, with the
per-region constants split into `PopoverTuning+Outline.swift`,
`PopoverTuning+Depth.swift` and `PopoverTuning+TopBar.swift`. The Makefile lists
Swift sources explicitly, so a new file has to be added to `SWIFT_SRC`.

### The menu bar icon

The icon is drawn natively in `BatteryPillIcon.swift`. It is a 30 x 14 design
space scaled to 12pt, with a 27 x 14 body and a D-shaped nub. The idle pill
knocks the level out at 0.85; the coloured pills draw it in the menu bar text
colour.
The drawing handler reads `NSAppearance.currentDrawing()` to decide whether the
menu bar is light or dark. The status item button's `effectiveAppearance` drives
the refresh when the wallpaper changes.

## Build and package

`make all` builds `bin/byper`, `bin/byper-mon.command` and `byper.app`.
`./pkg/build_pkg.sh` wraps the app into `byper-installer.pkg` and `.dmg`.
`BYPER_VERSION` overrides the package version.

The app bundle carries the CLI at `Contents/Resources/byper`, the installer
helper, the FiraCode fonts and the app icon. The package's postinstall copies
the CLI to `/usr/local/bin/byper`, sets `root:wheel` and `4755`, and installs the
completions.

## Installed paths

| Path | What |
|---|---|
| `/usr/local/bin/byper` | SUID CLI |
| `/usr/local/bin/byp`, `/usr/local/bin/chbypass` | Symlinks |
| `/usr/local/bin/byper-mon.command` | Standalone monitor, from `install.sh` |
| `/usr/local/share/zsh/site-functions/_byper`, `_byp` | Zsh completions |
| `/usr/local/share/bash-completion/completions/byper`, `byp` | Bash completions |
| `/Applications/byper.app` | Menu bar app |
