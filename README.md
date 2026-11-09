# <img src="https://github.com/Unnidentified/byper/blob/main/assets/icon.png?raw=true" width="85" height="85" align="absmiddle" alt="byper icon" /> byper

[![Build](https://github.com/Unnidentified/byper/actions/workflows/build.yml/badge.svg)](https://github.com/Unnidentified/byper/actions/workflows/build.yml)
[![CI](https://github.com/Unnidentified/byper/actions/workflows/ci.yml/badge.svg)](https://github.com/Unnidentified/byper/actions/workflows/ci.yml)

Charge bypass and a battery toolkit for Apple Silicon Macs (macOS 11+).

It holds your battery at whatever level you want and runs the whole machine off the charger, so net battery draw is 0 mA. There's a SUID-root CLI with real-time power telemetry, and a SwiftUI menu bar app that replaces the battery icon macOS gives you.

You don't need a local toolchain: just run the Build workflow in Actions, you'll get a `.pkg` and a `.dmg`

---

### Table of Contents

- [Building](#building)
- [Features](#features)
- [CLI Commands](#cli-commands)
- [How bypass works](#how-bypass-works)
- [Requirements](#requirements)
- [Installing](#installing)
- [Project layout](#project-layout)
- [Notes](#notes)
- [Credits](#credits)

---

## Building

1. Open the [Actions tab](https://github.com/Unnidentified/byper/actions) and run the **Build** workflow.
2. Leave `version` empty unless you want a specific label. It defaults to `0.0.0-dev.<run>`.
3. Tick `release` to publish a GitHub Release tagged `v<version>`. Leave it off to just get artifacts.
4. When the run finishes, grab the artifacts from the run page or from [Releases](https://github.com/Unnidentified/byper/releases).

| Artifact | What is it |
|---|---|
| `byper-installer-<version>.pkg` | Guided Installer package (recommended). Offers **Install** (keeps settings) and **Uninstall** (removes everything) |
| `byper-installer-<version>.dmg` | The same package in a disk image. |
| `SHA256SUMS.txt` | Checksums for both |

Building locally works the same way:

```bash
make all              # bin/byper, bin/byper-mon.command, byper.app
./pkg/build_pkg.sh    # byper-installer.pkg + byper-installer.dmg
```

`BYPER_VERSION` overrides the version baked into the package, which is what the Build workflow uses:

```bash
BYPER_VERSION=2.4.0 ./pkg/build_pkg.sh
```

---

## Features

| Stuff | whatsthat | Notes |
|---|---|---|
| **Core** | `byper` CLI | C/Obj-C, SUID root, at `/usr/local/bin/byper`. Also symlinked as `byp` and `chbypass` |
| **Menu bar** | `byper.app` | SwiftUI app that replaces the stock battery menu extra. Pre-rendered high-DPI icons, so it tracks percentage, charging state and whether bypass is actually engaged |
| **Telemetry** | SMC power rails | Per-rail wattage for SoC, DRAM, PMIC and DC-In, individual pack cell voltages, top CPU consumers with estimated wattage |
| **Bypass** | Hardware charge bypass | System runs off the adapter at 0 mA net battery draw, battery held at whatever level you picked |
| **Powersave** | Low Power Mode | Manual toggle, plus per-app auto-LPM while a designated app is frontmost. The manual switch wins over automation |
| **Caffeinate** | Display and idle sleep hold | "Always", or "Auto Enable on Bypass". Again, the manual switch wins |
| **Automations** | Auto-bypass | On charger connect, at login, or on external display attach |
| **Logging** | Session logger | Records CSV telemetry to your Desktop |
| **Shortcuts** | Hotkey and App Intents | Global `⌘⌥B`, plus App Intents for bypass on/off/toggle on macOS 13+ |

The main slider on the left is a continuous level, not a binary toggle. It progressively dims and disables the menu rows (bypass, powersave, caffeinate, settings) as you slide it down. Slide it back to the top and your previous state comes back.

---

## CLI Commands

```bash
byper            # Interactive real-time TUI monitor
byper on         # Engage charge bypass (plugged in)
byper off        # Resume standard charging
byper t          # Toggle bypass state
byper s          # One-line status summary
byper p          # Hardware power rails (SoC, DRAM, PMIC, cells, top process)
byper json       # Telemetry snapshot formatted as JSON
byper mon        # Continuous timestamped stream (non-TTY friendly)
byper help       # Command usage
```

A rail readout looks like this:

```text
[16:20:05] #1     Batt: 98% (AC Plugged) | Source: Power Adapter | State: ⏸ ON HOLD (BYPASS)
  ├─── Flow:   -858 mA | 10.90 W @ 12707 mV | Net Load: 10.90 W | Code: 0x01000000
  ├─── Rails:  SoC: 1.67 W | DRAM: 3.43 W | PMIC: 3.28 W | DC-In: 0.26 W
  ├─── Cells:  C1: 4242 mV | C2: 4242 mV | C3: 4236 mV
  └─── Top App: agy (PID: 25764, 93.4% CPU, ~0.49 W)
```

---

## How bypass works

macOS has no public API for "stop charging at the current level". Every surfaced knob (Optimized Charging, charge limits via `pmset`) is managed by **PowerUIAgent**, a system daemon whose in-memory charging state is neither persisted nor externally controllable.

So byper attaches to it:

1. Locate `PowerUIAgent` by PID via sysctl, no subprocess.
2. Write a small lldb batch script to `/tmp`, serialized with a lock file.
3. Fork an orphaned worker that runs `lldb -p <pid> --batch` as root, calls the daemon's own smart-charge entry points to enter *Not Charging / hold* mode, then detaches. The parent returns immediately.
4. Confirm the result by polling SMC registers, never by trusting the injection.

The actual charge inhibition is the SMC **mode-of-operation** value (`MoO`: 1 = charging, 7 = hold). The daemon sets it and the CLI reads the truth table back.

Direct SMC writes to the charge-limit keys were tested and are **rejected by the firmware**. `CHBI` writes don't stick, which is why injection is the load-bearing path rather than a shortcut.

Because the attach takes seconds, the UI's verify-poll gates truth and the engine retries on a 1.5s / 3.5s / 6s / 10s curve, capped at 45s. A toggle can therefore lag a tap by up to ~45s. That is expected, not a hang.

---

## Requirements

| Requirement | Why |
|---|---|
| **Apple Silicon** (M1-M4) | Builds target `arm64-apple-macos11.0`. Intel would need a universal2 build and untested SMC register maps |
| **macOS 11 Big Sur or newer** | Oldest release running Apple Silicon. App Intents need macOS 13+ |
| **SIP debug restriction relaxed** | Bypass attaches to `PowerUIAgent` with lldb, which stock SIP refuses |
| **Command Line Tools** | Provides `lldb`. The installer sets them up if missing |

Relax SIP's debugger restriction once, from Recovery Mode (Terminal):

```bash
csrutil enable --without debug
```

This partially disables SIP. Filesystem, kernel-extension and NVRAM protections stay on; only the debugger-attach policy changes. Without it, `byper on` fails with "Not allowed to attach" and bypass cannot work on that machine.

---

## Installing

```bash
curl -fsSL https://byper.org/install | bash
```

Or grab `byper-installer-<version>.pkg` from [Releases](https://github.com/Unnidentified/byper/releases/latest). Either way your settings survive upgrades, and the installer sets up Command Line Tools if you don't have them and installs the SUID helper.

From a source checkout:

```bash
make all
sudo ./install.sh
```

`install.sh` builds as the invoking user even when run with sudo, so build artifacts never end up root-owned.

> [!TIP]
> Seeing "App is damaged and can't be opened"? That's Gatekeeper on an ad-hoc signed app. Clear the quarantine attribute:
> ```bash
> xattr -cr /Applications/byper.app
> ```
> (or for a downloaded package: `xattr -c byper-installer-*.pkg`).

### Good Practices

`byper` must have `SUID` privileges in order to work, you can't just copy the .app to another computer and expect it to work. Spoiler: it won't, unless you reinstall it using the .pkg from the releases page. Check the permissions with:

```bash
ls -la /usr/local/bin/byper /Applications/byper.app/Contents/Resources/byper
```

If you copy the app by hand, re-apply:

```bash
sudo chown root:wheel /Applications/byper.app/Contents/Resources/byper
sudo chmod 4755      /Applications/byper.app/Contents/Resources/byper
```

### Uninstalling

Run the PKG and choose **Uninstall** (its postinstall removes every trace, including settings), or remove the paths in [Project layout](#project-layout) by hand and clear `~/Library/{Preferences/com.gefaass.byper.plist, Caches/com.gefaass.byper, Saved Application State/com.gefaass.byper.savedState}`.

---

## Project layout

```text
src/                    the engine: main.c (dispatcher + TUI), powerui.m (PowerUIAgent
                        bridge), smc.c (SMC registers), battery.c, power.c (rails + cells)
src/app/                the SwiftUI menu bar application and helper
pkg/                    package builder scripts (preinstall keeps settings;
                        uninstall-postinstall is a complete uninstaller)
completions/            Zsh and Bash shell completion
battery_icons_combined/ menu bar icon assets
docs/                   ARCHITECTURE, INSTALL, TROUBLESHOOTING, LIMITATIONS
.github/workflows/      build.yml (manual build, package, release), ci.yml (PR checks)
```

Installed paths:

| Path | What |
|---|---|
| `/usr/local/bin/byper` | SUID-root CLI (`chown root:wheel`, `chmod 4755`) |
| `/usr/local/bin/byp`, `/usr/local/bin/chbypass` | Symlinks to the same binary |
| `/usr/local/bin/byper-mon.command` (+ `byp-mon.command`) | Standalone monitor |
| `/usr/local/share/zsh/site-functions/_byper`, `_byp` | Zsh completions |
| `/usr/local/share/bash-completion/completions/byper`, `byp` | Bash completions |
| `/Applications/byper.app` | Menu bar app |

---

## Notes

> [!CAUTION]
> This utility modifies power management state using SMC keys and process injection into system daemons (`PowerUIAgent`). It is provided as-is, without warranty.

- **Toggling can lag.** PowerUIAgent debounces rapid opposite commands, so off-then-on within seconds can be swallowed or land 15-60s late. That's OS behaviour; byper works around it but cannot eliminate it.
- **Register signatures drift.** The mode-of-operation values, `NCR` reasons and rail keys were mapped empirically on specific macOS versions. A major update may shift them, and the verify-poll will surface it as "enabled but not holding".
- **Single-user assumptions.** A few fallbacks in `src/main.c` and the asset resolver reference `/Users/gefaass`. The PKG path works without them; a source install under a different account may need those literals adjusted.
- **No credentials in the repo.** The non-root dev path reads `BYP_SUDO_PASS` from the environment instead of embedding anything.

---

## Credits

| Project | Author | Link |
|---|---|---|
| byper | Unnidentified | [github.com/Unnidentified/byper](https://github.com/Unnidentified/byper) |
| FiraCode | Nikita Prokopov | [github.com/tonsky/FiraCode](https://github.com/tonsky/FiraCode) |
