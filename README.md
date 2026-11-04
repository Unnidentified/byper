# <img src="https://github.com/Unnidentified/byper/blob/main/assets/icon.png?raw=true" width="85" height="85" align="absmiddle" alt="byper icon" /> byper

True charge bypass and a hardware battery toolkit for Apple Silicon Macs (macOS 11+).

Hold the battery at any level and run the whole system off the AC adapter: 0 mA net battery draw. A SUID-root CLI engine with real-time power-rail telemetry, and a simple SwiftUI menu bar app that has an identical to stock mac battery icon.

---

### Table of Contents

- [Quick Start](#quick-start)
- [What you actually get](#what-you-actually-get)
- [The CLI](#the-cli)
- [Under the hood](#under-the-hood)
- [Disclaimers](#disclaimers)

---

## Quick Start

Just two steps:

1. Relax SIP's debugger restriction once, in Recovery Mode (Terminal):

```bash
csrutil enable --without debug
```

Bypass works by attaching to `PowerUIAgent` with `lldb`, and stock SIP forbids that. This partially disables SIP, but filesystem, kernel extension, and NVRAM protections stay fully on.

2. Install. Either route works:

```bash
curl -fsSL https://byper.org/install | bash
```

Or download `byper-installer-<version>.pkg` from [Releases](https://github.com/Unnidentified/byper/releases/latest). The installer preserves your settings on upgrade, configures Command Line Tools if needed, and provisions the SUID helper.

> [!TIP]
> **"App is damaged and can't be opened"?** Gatekeeper being Gatekeeper. Clear the quarantine attribute:
> ```bash
> xattr -cr /Applications/byper.app
> ```
> (or on a downloaded package: `xattr -c byper-installer-*.pkg`).

---

## What you actually get

### The engine

`byper` is a C/Obj-C binary at `/usr/local/bin/byper` (symlinked as `byp` and `chbypass`), running SUID root. It engages hardware charge bypass — the system runs off the adapter while the battery holds at whatever level you chose — and reads real-time telemetry straight from the SMC: per-rail wattage for SoC, DRAM, PMIC and DC-In, individual pack cell voltages, top CPU consumers with estimated wattage, and Low Power Mode control.

### The menu bar app

`byper.app` is a native SwiftUI menu bar extra that replaces the macOS battery menu:

- **Status bar icon** — pre-rendered high-DPI assets tracking percentage, charging state, and engine-confirmed bypass.
- **Glowy animated line** — a 24-hour temperature graph with live readouts.
- **The "Master?" slider** — a vertical rail that progressively dims and disables menu rows (bypass, LPM, caffeinate, settings). Restoring to the top recovers the previous state.
- **Session Logger** — a live CSV telemetry recorder to Desktop.
- **Shortcuts integration** — global hotkey (`⌘⌥B`) and App Intents for bypass on / off / toggle (macOS 13+).

The popover itself:

| Row | Function |
| :--- | :--- |
| **Byper** | Charge bypass: system runs off the adapter with 0 mA net battery draw. Optional "Off on exit" resumes charging when the app quits. |
| **Powersave** | Manual Low Power Mode, plus per-app auto LPM while a designated app is frontmost. Manual switch outranks automation. |
| **Caffeinate** | Prevents display and system idle sleep. "Always", or "Auto Enable on Bypass". Manual switch takes priority. |
| **Settings** | Automations: auto-bypass on charger connect, at login, or on external display attach. Session log export. |

Presets (Travel / Docked), Threshold, and Slow Charge are currently omitted from the latest builds — they proved unreliable. Bypass state persists across app closures until explicitly cleared with `byper off`, the menu bar toggle, or "Off on exit".

---

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

What a rail readout looks like:

```text
[16:20:05] #1     Batt: 98% (AC Plugged) | Source: Power Adapter | State: ⏸ ON HOLD (BYPASS)
  ├── Flow:   -858 mA | 10.90 W @ 12707 mV | Net Load: 10.90 W | Code: 0x01000000
  ├── Rails:  SoC: 1.67 W | DRAM: 3.43 W | PMIC: 3.28 W | DC-In: 0.26 W
  ├── Cells:  C1: 4242 mV | C2: 4242 mV | C3: 4236 mV
  └── Top App: agy (PID: 25764, 93.4% CPU, ~0.49 W)
```

---

## Under the hood

```text
src/                    the engine: main.c (dispatcher + TUI), powerui.m (PowerUIAgent
                        bridge), smc.c (SMC registers), battery.c, power.c (rails + cells)
app/                    the SwiftUI menu bar application and helper
pkg/                    package builder scripts (preinstall keeps settings;
                        uninstall-postinstall is a complete uninstaller)
completions/            Zsh and Bash shell completion
battery_icons_combined/ pre-rendered menu bar icon assets
docs/                   ARCHITECTURE, INSTALL, TROUBLESHOOTING, LIMITATIONS
```

Build it yourself (macOS 11+, Apple Silicon, Xcode Command Line Tools):

```bash
make app          # Build bin/byper and byper.app
sudo ./install.sh # Install CLI to /usr/local/bin and byper.app to /Applications
make pkg          # Assemble installer package (requires `make app` first)
```

Contributors must read [`forensic-agent-plan.md`](forensic-agent-plan.md) first: it enforces strict UI-vs-engine boundary rules and the hardware truth tables.

---

## Disclaimers

> [!CAUTION]
> This utility modifies power management state using SMC keys and process injection into system daemons (`PowerUIAgent`). It is provided as-is, without warranty.
