# <img src="https://github.com/Unnidentified/byper/blob/main/assets/icon.png?raw=true" width="38" height="38" align="absmiddle" alt="byper icon" /> byper

macOS true charge bypass and hardware battery utility for Apple Silicon (macOS 11+).

Hold battery charge at any level and power the system entirely from the AC adapter (0 mA net battery draw). Includes real-time hardware power rail monitoring via a SUID-root CLI and a native SwiftUI menu bar companion.

> [!IMPORTANT]
> **Private repository.** The development path in `src/powerui.m` embeds credentials for internal testing (see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#the-bypass-mechanism)). Do not make this repository public without removing them.

---

## Components

- **`byper` CLI** (`/usr/local/bin/byper`, symlinked as `byp` and `chbypass`): High-performance C/Obj-C engine operating with SUID root. Provides hardware bypass control, an interactive TUI monitor, and JSON/stream telemetry.
- **`byper.app`**: Native SwiftUI menu bar extra replacing the system battery icon. Exposes status, presets, automations, and quick controls.

---

## CLI Usage

```bash
byper            # Interactive real-time TUI monitor
byper on         # Engage charge bypass (run strictly off AC)
byper off        # Resume standard charging
byper t          # Toggle bypass state
byper s          # One-line status summary
byper p          # Hardware power rails (SoC, DRAM, PMIC, cells, top process)
byper json       # Telemetry snapshot formatted as JSON
byper mon        # Continuous timestamped stream (non-TTY friendly)
```

> [!NOTE]
> Bypass state persists in hardware across terminal closures until explicitly cleared with `byper off` or via the menu bar toggle.

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
- **Hardware Charge Bypass:** Direct AC operation with 0 mA net battery draw.
- **Slow Charge Trickle:** Alternating 20s hold / 40s burst duty-cycle to reduce battery degradation and thermal stress.
- **Per-Rail Power Telemetry:** Real-time wattage metrics for SoC, DRAM, PMIC, and DC-In, alongside individual cell voltages.
- **Process Power Attribution:** Automatic detection of top CPU/power consumers with estimated wattage.

### Menu Bar Companion (`byper.app`)
- **Status Bar Icon:** Pre-rendered high-DPI assets reflecting live battery level, bypass status (`⏸`), and thermal state.
- **Master Slider:** Left-rail slider that progressively dims menu rows; dragging to the bottom snapshots and disables all features (bypass, LPM, caffeine, automations). Restoring to top recovers previous state.
- **Profiles & Presets:** Quick-switch between snapshot presets (*Travel*, *Docked*); long-press to rename.
- **Automations:**
  - Auto-bypass on AC connection, login, or external display attachment.
  - SoC threshold trigger (engages hold when battery $\le$ configured target; manual resume snoozes until battery climbs back above).
- **System Controls:** Master caffeine toggle (auto-enabled during bypass) and per-app Low Power Mode (LPM) triggering when specific applications are focused.
- **Diagnostics & Integration:** CSV session recorder to Desktop with live REC timer, global hotkey (`⌘⌥B`), and App Intents for macOS Shortcuts (macOS 13+).
- **Self-Updater:** Warns when local project build is newer than installed application.

---

## Installation

### Prerequisites: System Integrity Protection (SIP)

Because `byper` attaches to `PowerUIAgent` via `lldb` to engage charge bypass, macOS debugger restrictions must be relaxed. In macOS Recovery (`Terminal`):

```bash
csrutil enable --without debug
```

This partially enables SIP—retaining filesystem, kernel extension, and NVRAM protections while permitting the required debugger attachment.

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
pkg/                    # Package builder scripts and uninstaller
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
