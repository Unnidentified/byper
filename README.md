# <img src="https://github.com/Unnidentified/byper/blob/main/assets/icon.png?raw=true" width="38" height="38" align="absmiddle" alt="byper icon" /> byper

macOS true charge bypass and hardware battery utility for Apple Silicon (macOS 11+).

Hold battery charge at any level and power the system entirely from the AC adapter (0 mA net battery draw). Includes real-time hardware power rail monitoring via a SUID-root CLI and a native SwiftUI menu bar companion.

> [!IMPORTANT]
> **SIP must be relaxed for bypass to work.** Run `csrutil enable --without debug` in Recovery. See [Prerequisites: System Integrity Protection (SIP)](#prerequisites-system-integrity-protection-sip) below for the full explanation.

---

## Components

- The `byper` CLI (`/usr/local/bin/byper`, symlinked as `byp` and `chbypass`): a C/Obj-C engine running SUID root. Provides hardware bypass control, an interactive TUI monitor, and JSON/stream telemetry.
- `byper.app`: a native SwiftUI menu bar extra replacing the system battery icon. Exposes status, presets, automations, and quick controls.

---

## CLI Usage

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

> [!NOTE]
> Bypass state persists in hardware across terminal closures until explicitly cleared with `byper off`, the menu bar toggle, or the app's "Off on exit" setting.

### Telemetry Output Sample

```text
[16:20:05] #1     Batt: 98% (AC Plugged) | Source: Power Adapter | State: ⏸ ON HOLD (BYPASS)
  ├─ Flow:   -858 mA | 10.90 W @ 12707 mV | Net Load: 10.90 W | Code: 0x01000000
  ├─ Rails:  SoC: 1.67 W | DRAM: 3.43 W | PMIC: 3.28 W | DC-In: 0.26 W
  ├─ Cells:  C1: 4242 mV | C2: 4242 mV | C3: 4236 mV
  └─ Top App: agy (PID: 25764, 93.4% CPU, ~0.49 W)
```

---

## Features

### Power & Telemetry Engine
- Hardware charge bypass. Direct AC operation with 0 mA net battery draw, held at the state of charge you engage at.
- Per-rail power telemetry. Real-time wattage metrics for SoC, DRAM, PMIC, and DC-In, alongside individual cell voltages.
- Process power attribution. Automatic detection of top CPU/power consumers with estimated wattage.
- Low Power Mode control (`byper lpm on|off`).

### Menu Bar Companion (`byper.app`)
- Status bar icon. Pre-rendered high-DPI assets reflecting the live battery level, charging and bypass states.
- Live telemetry. Thermal curve, adapter readout, and an apply counter in the popover header.
- Master slider. A left-rail slider that progressively dims menu rows; dragging to the bottom snapshots and disables all features (bypass, LPM, caffeine, automations). Restoring to top recovers previous state.
- Diagnostics and integration. CSV session recorder to Desktop with live REC timer, global hotkey (`⌘⌥B`), and App Intents for macOS Shortcuts (bypass on / off / toggle; macOS 13+).

### Feature set

One row per feature in the popover:

| Feature | What it does |
| :--- | :--- |
| **Byper** | Charge bypass: the system runs off the adapter with 0 mA net battery draw from the moment it engages. Optional "Off on exit" resumes charging when the app quits. |
| **Powersave** | Manual Low Power Mode, plus per-app auto LPM: pick apps and macOS drops into LPM while one of them is frontmost. The manual switch outranks the automation. |
| **Caffeinate** | Keeps the display awake. "Always", or "Auto Enable on Bypass" which arms it for every bypass engagement. The manual switch has priority. |
| **Settings** | Automations: auto bypass on charger connect, at login, or on external display attach. Plus the session Logger (CSV to Desktop with a live timer). |

Global controls on top of the rows: the master slider and the `⌘⌥B` hotkey.

> [!NOTE]
> **Presets (Travel / Docked), Threshold, and Slow Charge are not in the build.** They misbehaved (a threshold trigger that missed with the lid closed, a Slow Charge duty cycle that re-engaged bypass on its own), so they are compiled out rather than shipped unreliable. They may return once fixed.

Build here with `make app && ./pkg/build_pkg.sh`. That produces `byper-installer.pkg` and `byper-installer.dmg` (ships via Releases).

### Changelog

#### 2.2.7
This one is all about the small stuff that made the app feel unreliable. Toggling bypass used to leave the seconds counter running in the background — it now stops the moment the apply finishes, whether it worked or not, and mashing the toggle can no longer stack applies on top of each other. Checking "On Bypass" while bypass is already running now lights up Caffeinate right away (previously it silently did nothing), and the row shows the real caffeinate state no matter what turned it on. Switching between watched apps in per-app Powersave is near-instant now instead of lagging a beat behind.

The session log export got a proper upgrade too: 16 columns per sample now, including pack voltage, the exact not-charging reason code the PMU reports, cycle count, adapter wattage, and whether LPM and Caffeinate were active at each sample. Much better for figuring out what actually happened during a session.

Also fixed in this round: the menu bar pill used to flicker when you clicked it (the app was fighting macOS's own highlight — that's gone), the thermal graph had occasional sudden cuts from sensor misreads (anything jumping more than 8°C between polls is discarded now), and the installer got simpler — the choices just say "Install" and "Uninstall", and the app opens by itself when the install finishes.

#### 2.2.6
This release was a consistency pass over the things that acted up day to day. The battery icon now only shows states the engine has actually confirmed: the plug appears when the apply really completes, and the bolt shows while the battery is genuinely charging — no more flicker, no more stale bolt sitting on top of a hold, and no more idle gap right after you disable bypass while the PMU catches up.

There was also a random one: unplugging the charger could erase the "remembered bypass", so plugging back in sometimes just... didn't re-engage. Two pollers were racing each other on the plug event; they share the same edges now.

Caffeinate and Powersave got clear priority rules. The manual switch always wins over the automations, and the per-app LPM reconciler now works off desired state instead of one-shot triggers — it heals failed applies, picks back up when you turn the manual switch off with a watched app still focused, and cleans up when you remove apps from the list. The installer's Upgrade path also got a small fix: it resets only the bypass state before swapping files, so an upgrade can't inherit a stale hold, while everything else stays untouched.

On the looks side: the popover is squarer now (280 → 244 pt) and the "Bypass Charge" row is just called **Byper**.

#### 2.2.5
- One build for everyone: the reduced feature set (Byper, Powersave, Caffeinate, Settings) is the product; variant naming dropped.
- Installer hardened: postinstall works over any previously installed variant; the uninstaller resets the hardware to stock before removing anything.

#### 2.2.0
- Distribution moved to DMG-wrapped installers.
- Credential scrub: an embedded dev credential removed from the source and the entire git history (force-push); the dev path now reads `BYP_SUDO_PASS` from the environment.
- Powersave, Caffeinate and Settings reliability fixes; per-app auto LPM introduced.

#### 2.1.0
- Initial build.

---

## Installation

### Prerequisites: System Integrity Protection (SIP)

Because `byper` attaches to `PowerUIAgent` via `lldb` to engage charge bypass, macOS debugger restrictions must be relaxed. In macOS Recovery (`Terminal`):

```bash
csrutil enable --without debug
```

This partially enables SIP. It keeps filesystem, kernel extension, and NVRAM protections while permitting the debugger attachment.

### Package Installer (Recommended)
Download `byper-installer.pkg` from Releases. The package manages clean upgrades (preserving settings), configures Command Line Tools (`lldb`) if missing, and provisions the bypass helper via standard macOS authorization.

### Building from Source

Requirements: macOS 11+, Apple Silicon, Xcode Command Line Tools.

```bash
make app          # Build bin/byper and byper.app
sudo ./install.sh # Install CLI to /usr/local/bin and byper.app to /Applications
```

See [`docs/INSTALL.md`](docs/INSTALL.md) for SUID details, permissions, and shell completion setup (Zsh/Bash).

---

## Documentation

| Document | Description |
| :--- | :--- |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | PowerUIAgent bridge, lldb injection mechanics, SMC registers, state machines |
| [`docs/INSTALL.md`](docs/INSTALL.md) | PKG installer scripts, source compilation, SUID requirements, uninstallation |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | SUID issues, linker failures, attach-denied troubleshooting, quarantine attributes |
| [`docs/CUSTOM-FILE-ICONS.md`](docs/CUSTOM-FILE-ICONS.md) | How the pkg's Finder custom icon is set (NSWorkspace), and why Rez/DeRez approaches fail |
| [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) | SIP boundary (`csrutil enable --without debug`), OS-level debounce limits, supported hardware |

---

## Repository Layout

```text
src/
├── main.c              # CLI dispatcher and interactive TUI
├── powerui.m           # PowerUI system framework bridge
├── smc.c               # Apple Silicon SMC register interface
├── battery.c           # IOPowerSources / Smart Battery reader
├── power.c             # Power rail parser (SoC, DRAM, PMIC) & cell telemetry
└── app/                # SwiftUI menu bar application and helper
pkg/                    # Package builder scripts (preinstall = install path keeping
                        # settings; uninstall-postinstall = complete uninstaller)
completions/            # Zsh and Bash shell completion scripts
battery_icons_combined/ # Pre-rendered menu bar icon assets
bar-app.md              # Companion app UI specification
forensic-agent-plan.md  # Engineering directives and hardware truth tables
```

---

## Development

```bash
make            # Compile CLI and application into bin/ and byper.app/
make clean      # Remove build artifacts
./pkg/build_pkg.sh  # Assemble installer package (requires `make app` first)
```

Contributors must review [`forensic-agent-plan.md`](forensic-agent-plan.md) before submitting code changes; it enforces strict UI-vs-engine boundary rules and hardware truth tables.

---

## Disclaimers

> [!CAUTION]
> This utility modifies power management state using SMC keys and process injection into system daemons (`PowerUIAgent`). It is provided as-is without warranty. Monitor system temperatures under sustained heavy workloads while running on bypass, and ensure your power adapter provides adequate wattage for peak system load.
