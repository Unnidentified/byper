



<img width="524" height="521" alt="icon" src="https://github.com/user-attachments/assets/cef64c31-00c1-4df0-b52b-0e7601ede0d3" />

# byper — a macOS Charge Bypass & Battery Utility

A native Apple Silicon utility that gives you manual control over battery charging on macOS: hold the battery at its current charge and run the system directly off the AC adapter (0 mA battery draw), plus real-time hardware power telemetry.

Ships as two halves of one binary:

- **`byper` CLI** (`/usr/local/bin/byper`, symlinked as `byp` / `chbypass`) — C/ObjC engine, SUID root.
- **`byper.app`** — SwiftUI menu bar companion that wraps the CLI. Replaces the stock battery menu extra with a custom icon, live telemetry, presets, and automations.

> [!IMPORTANT]
> **Private repository.** The dev-path fallback in `src/powerui.m` embeds a sudo password by design (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#the-bypass-mechanism)). Do not make this repo public without removing it.

---

## Quick usage

```bash
byper            # live power + bypass monitor (interactive TUI)
byper on         # engage bypass / hold: charging stops, system runs on AC
byper off        # resume normal charging
byper t          # toggle hold / charging
byper s          # one-line status summary
byper p          # hardware power rails breakdown (SoC, DRAM, PMIC, cells, top app)
byper json       # machine-readable JSON telemetry
byper mon        # stacked timestamped monitor stream (non-TTY friendly)
```

When bypass is engaged, closing the terminal does **not** undo it — the hold lives in the hardware until `byper off` (or the app's switch) clears it.

Sample monitor output:

```text
[16:20:05] #1     Batt: 98% (AC Plugged) | Source: Power Adapter | State: ⏸ ON HOLD (BYPASS)
  ├─ Flow:   -858 mA | 10.90 W @ 12707 mV | Net Load: 10.90 W | Code: 0x01000000
  ├─ Rails:  SoC: 1.67 W | DRAM: 3.43 W | PMIC: 3.28 W | DC-In: 0.26 W
  ├─ Cells:  C1: 4242 mV | C2: 4242 mV | C3: 4236 mV
  └─ Top App: agy (PID: 25764, 93.4% CPU, ~0.49 W)
```

## Installation

**Recommended:** download `byper-installer.pkg` from Releases and run it. The guided installer offers *Upgrade* (keeps settings) and *Uninstall*; the bypass helper is enabled by an in-app admin prompt on first use, and Command Line Tools (for `lldb`) auto-install if missing.

**From source:**

```bash
make app          # builds bin/byper + byper.app (arm64, min macOS 11)
sudo ./install.sh # installs CLI to /usr/local/bin + app to /Applications
```

Details, including shell completions and the SUID requirement: [docs/INSTALL.md](docs/INSTALL.md).

## Menu bar app features

- **Custom battery icon** in the status bar with pre-rendered high-DPI assets and charge-state coloring.
- **Master slider** (left rail): drag down to fade menu rows out chronologically; hitting the bottom snapshots and disables everything (bypass, LPM, caffeine, automations) — returning to the top restores the setup.
- **Presets** (Travel / Docked): activate to snapshot and switch; click again to restore. Long-press to rename.
- **Automations**: Auto Bypass on Connect / at Login / on external Display, and **Auto Bypass at Threshold** (engages hold when SoC ≤ threshold; manual resume snoozes until the battery climbs back above).
- **Slow Charge**: 20 s hold / 40 s burst trickle duty-cycle to creep the battery toward a target instead of fast-charging. Mutually exclusive with Bypass at every layer.
- **Caffeinate**: master toggle + auto-enable while bypass is active.
- **Per-App Auto LPM**: Low Power Mode engages while a configured app is frontmost.
- **Session Logger**: CSV battery telemetry to the Desktop with live REC timer and export.
- **Global hotkey** ⌘⌥B toggles the popover; **Shortcuts/App Intents** expose Bypass On/Off/Toggle and presets (macOS 13+).
- **Self-updater**: prompts when the project-folder build is newer than the installed app.

## Documentation

| Doc | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How bypass actually works (PowerUIAgent + lldb injection), component map, state machines |
| [docs/INSTALL.md](docs/INSTALL.md) | PKG installer, install.sh, building from source, uninstalling |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | SUID gotchas, rebuild linker failures, attach-denied diagnostics, quarantine |
| [docs/LIMITATIONS.md](docs/LIMITATIONS.md) | SIP boundary, OS-side debounce, supported hardware |

## Repository layout

```
src/            C/ObjC engine: main.c (CLI+TUI), powerui.m (PowerUI bridge),
                smc.c, battery.c, power.c
src/app/        SwiftUI menu bar app + install helper
pkg/            PKG installer scripts (preinstall = complete uninstaller)
completions/    Zsh + Bash completions
battery_icons_combined/  pre-rendered battery icon assets
bar-app.md      original design blueprint for the companion app
forensic-agent-plan.md   engineering directives (isolation rules, truth tables)
```

## Development

```bash
make            # build CLI + app into bin/ and byper.app/
make clean
./pkg/build_pkg.sh   # assemble byper-installer.pkg (needs `make app` first)
```

Before touching the code, read [`forensic-agent-plan.md`](forensic-agent-plan.md) — it defines the strict UI-vs-engine isolation rules and the hardware truth tables this project is built around.

## Warning

This tool pokes hardware power management via SMC keys and debugger injection into a system daemon. It is provided as-is, with no warranty. Use at your own risk; keep an eye on thermals when running on AC with the battery held.
