# <img src="https://github.com/Unnidentified/byper/blob/main/assets/icon.png?raw=true" width="85" height="85" align="absmiddle" alt="byper icon" /> byper

Charge bypass and a battery toolkit for Apple Silicon Macs (macOS 11+).

It holds your battery at whatever level you want and runs the whole machine off the charger, so net battery draw is 0 mA. There's a SUID-root CLI with real-time power telemetry, and a SwiftUI menu bar app that replaces the battery icon macOS gives you.

## Quick Start

Two steps.

First, relax SIP's debugger restriction once from Recovery Mode (Terminal):

```bash
csrutil enable --without debug
```

Bypass works by attaching to `PowerUIAgent` with `lldb`, and stock SIP doesn't let you do that. This partially disables SIP, but filesystem, kernel extension, and NVRAM protections stay on.

Then install:

```bash
curl -fsSL https://byper.org/install | bash
```

Or grab `byper-installer-<version>.pkg` from [Releases](https://github.com/Unnidentified/byper/releases/latest). Either way your settings survive upgrades, and the installer sets up Command Line Tools if you don't have them and installs the SUID helper.

> [!TIP]
> Seeing "App is damaged and can't be opened"? That's Gatekeeper. Clear the quarantine attribute:
> ```bash
> xattr -cr /Applications/byper.app
> ```
> (or for a downloaded package: `xattr -c byper-installer-*.pkg`).

## What you get

### The engine

`byper` is a C/Obj-C binary at `/usr/local/bin/byper` (also symlinked as `byp` and `chbypass`), running SUID root. It engages hardware charge bypass, so the system runs off the adapter while the battery sits at the level you picked. It also reads telemetry straight from the SMC: per-rail wattage for SoC, DRAM, PMIC and DC-In, individual pack cell voltages, the top CPU consumers with estimated wattage, and Low Power Mode control.

### The menu bar app

`byper.app` is a SwiftUI menu bar app that replaces the macOS battery menu. The status bar icon uses pre-rendered high-DPI assets, so it tracks percentage, charging state, and whether bypass is actually active. There's a 24-hour temperature graph with live readouts, a session logger that records CSV telemetry to your Desktop, and a global hotkey (⌘⌥B) plus App Intents for bypass on/off/toggle on macOS 13+.

The main slider on the left progressively dims and disables the menu rows (bypass, LPM, caffeinate, settings). Slide it back to the top and your previous state comes back.

What each row does:

| Row | Function |
| :--- | :--- |
| **Byper** | Charge bypass: the system runs off the adapter with 0 mA net battery draw. Optional "Off on exit" resumes charging when the app quits. |
| **Powersave** | Manual Low Power Mode, plus per-app auto LPM while a designated app is frontmost. The manual switch wins over automation. |
| **Caffeinate** | Prevents display and system idle sleep. "Always", or "Auto Enable on Bypass". Again, the manual switch wins. |
| **Settings** | Automations: auto-bypass on charger connect, at login, or on external display attach. Session log export. |

Presets (Travel / Docked), Threshold, and Slow Charge aren't in the latest builds — they turned out to be unreliable. Bypass state survives app restarts until you turn it off with `byper off`, the menu bar toggle, or "Off on exit".

## The CLI

```bash
byper            # Interactive real-time TUI monitor
byper on         # Engage charge bypass (plugged in)
byper off        # Resume standard charging
byper t          # Toggle bypass state
byper s          # One-line status summary
byper p          # Hardware power rails (SoC, DRAM, PMIC, cells, top process)
byper json       # Telemetry snapshot formatted as JSON
byper mon        # Continuous timestamped stream (non-TTY friendly)
```

A rail readout looks like this:

```text
[16:20:05] #1     Batt: 98% (AC Plugged) | Source: Power Adapter | State: ⏸ ON HOLD (BYPASS)
  ├─── Flow:   -858 mA | 10.90 W @ 12707 mV | Net Load: 10.90 W | Code: 0x01000000
  ├─── Rails:  SoC: 1.67 W | DRAM: 3.43 W | PMIC: 3.28 W | DC-In: 0.26 W
  ├─── Cells:  C1: 4242 mV | C2: 4242 mV | C3: 4236 mV
  └─── Top App: agy (PID: 25764, 93.4% CPU, ~0.49 W)
```

## Project layout

```text
src/                    the engine: main.c (dispatcher + TUI), powerui.m (PowerUIAgent
                        bridge), smc.c (SMC registers), battery.c, power.c (rails + cells)
app/                    the SwiftUI menu bar application and helper
pkg/                    package builder scripts (preinstall keeps settings;
                        uninstall-postinstall is a complete uninstaller)
completions/            Zsh and Bash shell completion
battery_icons_combined/ menu bar icon assets
docs/                   ARCHITECTURE, INSTALL, TROUBLESHOOTING, LIMITATIONS
```

You can build it yourself (macOS 11+, Apple Silicon, Xcode Command Line Tools):

```bash
make app          # Build bin/byper and byper.app
sudo ./install.sh # Install CLI to /usr/local/bin and byper.app to /Applications
make pkg          # Assemble installer package (requires `make app` first)
```

## Disclaimers

> [!CAUTION]
> This utility modifies power management state using SMC keys and process injection into system daemons (`PowerUIAgent`). It is provided as-is, without warranty.
