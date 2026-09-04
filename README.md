# ⚡ `byp` — macOS Charge Bypass & Hardware Telemetry Toolkit

A lightweight hardware charge bypass controller and real-time Apple Silicon power telemetry toolkit for macOS.

Enables manual control over battery charging inhibition (allowing your MacBook to run directly on AC adapter power with 0 mA battery draw) with a stacked real-time debug monitor and two-switch interactive selector.

---

## 🚀 Quick Usage

### 1. Interactive Selector & Control Switchboard
Launch the interactive switchboard simply by typing:
```bash
byp
```
Shows:
- **Switch 1:** Bypass / Hold State `[🟢 ON (ACTIVE)]` / `[⚪ OFF (CHARGING)]`
- **Switch 2:** Live Debug Monitor Stream `[▶ RUNNING]` / `[⏸ PAUSED]`
- Live battery level, charging mode, net flow, and individual hardware rails.

### 2. Direct CLI Commands
```bash
# Engage AC Bypass / On Hold mode (persists in background after closing terminal)
byp on        # or: byp -on

# Resume normal full charging (100%)
byp off       # or: byp -off

# Launch stacked timestamped debug telemetry monitor
byp mon       # or: byp -m

# Instant Hardware Power Rails Breakdown (SoC, DRAM, PMIC, Cells, Top Apps)
byp p         # or: byp -p

# Quick compact battery status
byp s         # or: byp -s

# Toggle state
byp t         # or: byp -t
```

---

## 🔒 Persistent Background Operation

- When Bypass is enabled (`byp on` or Switch 1 `ON`), **closing the terminal does NOT kill bypass charging**.
- The bypass state stays active in the hardware/daemon until you explicitly call `byp off`.
- Closing the terminal or pressing `Ctrl+C` in the monitor terminates **only** the log/debug monitor process.

---

## 📊 Stacked Debug Monitor Output (`byp mon`)

Each sample is printed with full timestamps and debug telemetry stacked sequentially:

```text
[16:20:05] #1     Batt: 98% (AC Plugged) | Source: Power Adapter | State: ⏸ ON HOLD (BYPASS)
  ├─ Flow:   -858 mA | 10.90 W @ 12707 mV | Net Load: 10.90 W | Code: 0x01000000
  ├─ Rails:  SoC: 1.67 W | DRAM: 3.43 W | PMIC: 3.28 W | DC-In: 0.26 W
  ├─ Cells:  C1: 4242 mV | C2: 4242 mV | C3: 4236 mV
  └─ Top App: agy (PID: 25764, 93.4% CPU, ~0.49 W)
───────────────────────────────────────────────────────────────────────────────────────────────
[16:20:07] #2     Batt: 98% (AC Plugged) | Source: Power Adapter | State: ⏸ ON HOLD (BYPASS)
  ├─ Flow:   -858 mA | 10.90 W @ 12707 mV | Net Load: 10.90 W | Code: 0x01000000
  ├─ Rails:  SoC: 1.65 W | DRAM: 3.40 W | PMIC: 3.25 W | DC-In: 0.26 W
  ├─ Cells:  C1: 4242 mV | C2: 4242 mV | C3: 4236 mV
  └─ Top App: WindowServer (PID: 415, 9.2% CPU, ~0.05 W)
───────────────────────────────────────────────────────────────────────────────────────────────
```

---

## 🛠️ Installation & Updating

```bash
cd "/Users/gefaass/Desktop/addon-modules/working/macos-ch.bypass #2"
sudo ./install.sh
```
Installs both `/usr/local/bin/byp` and `/usr/local/bin/chbypass`.

---

## 🖥️ Menu Bar Companion App (`byper.app`)

A native SwiftUI menu bar app wraps the CLI (`make app` → `byper.app`). Install to `/Applications` and launch; it lives in the status bar and drives the same CLI binary (SUID root) — no duplicated logic.

### Build & Install
```bash
make app          # assembles byper.app (CLI + SwiftUI binary, min macOS 11.0 Big Sur)
# then copy to /Applications and keep the SUID bit on Contents/Resources/byper:
sudo chown root:wheel /Applications/byper.app/Contents/Resources/byper
sudo chmod 4755   /Applications/byper.app/Contents/Resources/byper
```
> ⚠️ **SUID is load-bearing**: a non-SUID CLI prints `enabled [✓]` but the SMC write silently fails. If bypass "enables" without engaging, check `ls -la` for `-rwsr-xr-x root:wheel` on both the bundle CLI and `/usr/local/bin/byper`.

### App Features
- **Master slider** (left rail): continuous 0→1 level. Dragging down fades menu rows out chronologically (top rows first, Settings last) with a visible grey floor; hitting the bottom snapshots + disables everything (bypass, LPM, caffeine, all automations), returning to the top restores the setup. Persisted as `byp_master_level`.
- **Presets (Travel / Docked)**: click to activate, click again to restore your pre-activation setup. Fresh activations always start from factory defaults; manual changes made while a mode is active are captured and reused on re-activation. Long-press a name to rename.
- **Automations**: Auto Bypass on Connect / at Login / on external Display, and **Auto Bypass at Threshold** (engages hold when SoC ≤ threshold; a manual resume snoozes it until the battery climbs back above). Threshold and background polls run in `.common` run-loop mode so they keep working with menus open or the screen asleep.
- **Caffeinate**: master toggle + "Auto Enable on Bypass" (holds a `PreventUserIdleDisplaySleep` assertion while bypass is active).
- **Per-App Auto LPM**: per-app checkmarks; LPM engages while a configured app is frontmost.
- **Session Logger**: records battery telemetry to a CSV on the Desktop; live REC timer, reset, export.
- **Global hotkey**: ⌘⌥B toggles the popover from anywhere.
- **App Intents / Shortcuts**: Bypass On/Off/Toggle, Travel & Docked presets (macOS 13+).
- **Self-updater**: on launch, if the project-folder build is newer than the installed app, it prompts to update (admin prompt attributed to byper).

### Gotchas (learned the hard way)
- `scaleEffect(0.70)` on the row switches does **not** shrink their layout footprint — inline numbers (threshold %, transition timer) overflow the row unless the switch's frame is clamped.
- The popover auto-refit only fires on subscribed flags; any new expandable section must be added to the `Publishers.Merge` in `AppDelegate.applicationDidFinishLaunching` (or, on macOS 13+, rely on `NSHostingSizingOptions.preferredContentSize`).
- Timers added with `Timer.scheduledTimer` stall in `.common`-tracked modes (open menus, screen sleep) — add them to `RunLoop.main` with `.common` explicitly.
