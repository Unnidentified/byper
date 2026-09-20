# <img src="https://github.com/Unnidentified/byper/blob/main/assets/icon.png?raw=true" width="38" height="38" align="absmiddle" alt="byper icon" /> byper

macOS true charge bypass and hardware battery utility for Apple Silicon (macOS 11+).

Hold battery charge at any level and power the system entirely from the AC adapter (0 mA net battery draw). Includes real-time hardware power rail monitoring via a SUID-root CLI and a native SwiftUI menu bar companion.

> [!IMPORTANT]
> **SIP must be relaxed for bypass to work.** Run `csrutil enable --without debug` in Recovery. See [prerequisites](#prerequisites-system-integrity-protection-sip) below for the full explanation.

## Components

byper has two interfaces around a shared hardware engine:

- **`byper` CLI** (`/usr/local/bin/byper`, symlinked as `byp` and `chbypass`): A C/Obj-C engine running SUID root. Manages hardware charge bypass, provides an interactive real-time TUI monitor, per-rail power telemetry, and machine-readable JSON streaming.
- **`byper.app`**: A native SwiftUI menu bar extra replacing the macOS battery menu. Exposes hardware status, toggles, automations, and quick controls directly from the menu bar.

## Features

### Charge Bypass & Power Engine
- **Hardware charge bypass:** Runs the Mac directly from the AC adapter at 0 mA net battery draw, holding the battery at whatever level you choose.
- **Per-rail telemetry:** Real-time wattage instrumentation for SoC, DRAM, PMIC, and DC-In, alongside individual pack cell voltages.
- **Process attribution:** Identifies top CPU and power consumers with estimated wattage.
- **Low Power Mode control:** Direct toggle via `byper lpm on|off`.

### Menu Bar Companion (`byper.app`)
- **Status bar icon:** Pre-rendered high-DPI assets reflecting battery percentage, charging state, and engine-confirmed bypass.
- **Glowy animated line:** 24-hour temp graph with live readouts.
- **The "Master?" slider:** Vertical rail slider that progressively dims and disables menu rows (bypass, LPM, caffeinate, settings). Restoring to top recovers previous state.
- **Session Logger:** Live CSV telemetry recorder to Desktop with timestamped metrics.
- **Shortcuts integration:** Global hotkey (`⌘⌥B`) and App Intents for macOS Shortcuts (bypass on / off / toggle; macOS 13+).

### Popover Controls

| Row | Function |
| :--- | :--- |
| **Byper** | Charge bypass: system runs off the adapter with 0 mA net battery draw. Optional "Off on exit" resumes charging when the app quits. |
| **Powersave** | Manual Low Power Mode, plus per-app auto LPM: drops into LPM while a designated app is frontmost. Manual switch outranks automation. |
| **Caffeinate** | Prevents display and system idle sleep. "Always", or "Auto Enable on Bypass". Manual switch takes priority. |
| **Settings** | Automations: auto-bypass on charger connect, at login, or on external display attach. Includes session log export. |
> Presets (Travel / Docked), Threshold, and Slow Charge are currently omitted from the latest builds. (proved unreliable). Bypass state persists app closures until explicitly cleared with `byper off`, the menu bar toggle, or the app's "Off on exit" setting.

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

### Telemetry Output Sample

```text
[16:20:05] #1     Batt: 98% (AC Plugged) | Source: Power Adapter | State: ⏸ ON HOLD (BYPASS)
  ├─ Flow:   -858 mA | 10.90 W @ 12707 mV | Net Load: 10.90 W | Code: 0x01000000
  ├─ Rails:  SoC: 1.67 W | DRAM: 3.43 W | PMIC: 3.28 W | DC-In: 0.26 W
  ├─ Cells:  C1: 4242 mV | C2: 4242 mV | C3: 4236 mV
  └─ Top App: agy (PID: 25764, 93.4% CPU, ~0.49 W)
```

---

## Installation & Setup

### Prerequisites: System Integrity Protection (SIP)

Because `byper` attaches to `PowerUIAgent` via `lldb` to engage charge bypass, macOS debugger restrictions must be relaxed once in Recovery Mode (`Terminal`):

```bash
csrutil enable --without debug
```

This partially enables SIP: filesystem, kernel extension, and NVRAM protections remain fully enabled while allowing the debugger attachment required by the engine.

### Option A: One-Line Install (Recommended)

```bash
curl -fsSL https://byper.org/install | bash
```

Downloads the latest installer package from Releases, verifies it, and launches the standard macOS Installer.

### Option B: Package Installer (Manual)

Download `byper-installer-<version>.pkg` from [Releases](https://github.com/Unnidentified/byper/releases/latest). The installer preserves your settings on upgrade, configures Command Line Tools if needed, and provisions the SUID helper.

> [!TIP]
> **"App is damaged and can't be opened" warning?** If macOS Gatekeeper blocks the app with a "move to Trash" prompt, clear the quarantine attribute in Terminal:
> ```bash
> xattr -cr /Applications/byper.app
> ```
> (or on a downloaded package: `xattr -c byper-installer-*.pkg`).
### Option C: Building from Source

Requirements: macOS 11+, Apple Silicon, Xcode Command Line Tools.

```bash
make app          # Build bin/byper and byper.app
sudo ./install.sh # Install CLI to /usr/local/bin and byper.app to /Applications
```

See [`docs/INSTALL.md`](docs/INSTALL.md) for full SUID details, permissions, and shell completion setup (Zsh/Bash).

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
make pkg        # Assemble installer package (requires `make app` first)
```

Contributors must review [`forensic-agent-plan.md`](forensic-agent-plan.md) before submitting code changes; it enforces strict UI-vs-engine boundary rules and hardware truth tables.

---

## Changelog
#### 2.3.1
- Fixed the unplug-while-bypassing desync: pulling AC during a bypass apply now cancels the in-flight engine command, clears the pending-apply latch, and bumps the apply round so the dead round's completion is discarded. Previously the leaked pending latch made the replug re-engage a silent no-op — the icon and switch latched bypass while the hardware never engaged it, and off/on from then on did nothing.
- The steady-state reconcile now walks both the UI mode and the engine-confirmed mode back from hardware truth, so a bypass whose hold silently dropped recovers instead of staying latched. The old guard was self-blocking (`!bypassActiveOrPending` is true whenever the UI is on bypass).
- Apply failures now sync both the UI mode and the engine-confirmed mode to hardware truth, so a failed engage can't strand the icon on bypass (nor a stale hold strand it on charging).

#### 2.3.0
- Interruptible bypass toggle: flipping the toggle mid-apply cancels the in-flight engine command (SIGTERM→SIGKILL, orphan LLDB worker cleanup, lock file removal) instead of waiting for the full verify window; stale async completions are discarded by round ID, and after an interrupt a delayed IOKit re-poll reconciles UI state with hardware truth in case the killed command had already landed.
- Interrupt teardown now clears all transition/counter timers and the stale `transitionEndTime` so a post-interrupt toggle never inherits a finished-look animation.

#### 2.2.9
- Fixed installer hang on battery: `preinstall` and `uninstall-postinstall` scripts check `acAttached` before attempting hardware hold release, and the engine's `powerui_disable_hold` returns immediately when on battery instead of running an impossible 45-second verification loop waiting for AC.

#### 2.2.8
- Fast bypass reconnect & hardware hold synchronization: tightened verification injection retries from 15s to 1.5s/3.5s/6s/10s so `PowerUIAgent` receives the hold call immediately after the AC handshake settles, turning the MagSafe plug LED green promptly without lag.
- Disconnect state persistence: unplugging with bypass enabled preserves the configured state in the UI toggle (dimmed on-battery display with `powerplug.fill` icon) and re-engages seamlessly on replug.
- Reconcile protection: transient charging state during initial USB-PD negotiation no longer overrides user bypass intent.
- Engine failure honesty: if a hardware hold fails to land after the full verification window, the UI honestly reverts to charging instead of stranding in bypass.
- Display & login item: display auto-hold registration uses native `CGDisplayRegisterReconfigurationCallback` with external display detection; login item registration strictly follows the `autoHoldAtLogin` setting.
- Caffeinate assertions: system and display sleep prevention combined with native `caffeinate -d -i` subprocess.

#### 2.2.7
- Toggle counter no longer loops: the counter ends the instant its apply finishes (success or fail), same-mode applies can't stack, and a failed apply no longer poisons the next toggle.
- "On Bypass" (caffeinate) checked during an active bypass lights the Caffeinate row immediately; the row now reflects the effective caffeinate state from either source.
- Per-app Powersave switching is much faster (synchronous apply) and re-asserts LPM if the OS flag is off while a watched app is frontmost.
- Session log export extended to 16 columns per sample: voltage, NCR code + description, cycle count, adapter watts, LPM and Caffeinate state, battery chip, pack mV.
- Installer: choices are literally "Install" and "Uninstall"; the app opens automatically after install/upgrade.
- Fixed the menu bar pill flicker on click (the app no longer fights AppKit's own highlight) and sudden graph cuts (sensor misreads above 8°C between polls are rejected).

#### 2.2.6
- Menu bar popover narrowed to a squared layout (280 → 244 pt).
- Row label "Bypass Charge" renamed to "Byper".
- Engine-confirmed icon state: the plug lands when the apply completes and tracks the hold; the bolt shows the moment charging is requested and stays while the hardware confirms it.
- Fixed a poller race where the CLI status poll could erase the bypass memory on unplug, so a remembered bypass failed to re-engage on the next charger connect (was random).
- Caffeinate row lights up only from the manual switch; auto-on-bypass keeps working without hijacking the row. The manual switch has priority.
- Powersave hardened: the manual switch outranks per-app auto LPM; the auto reconciler is desired-state based (self-heals failed applies, re-engages after manual-off with an auto app focused, clears latched state) and respects master-slider stand-down.
- Installer (Upgrade path) resets only the bypass state to default before swapping files; every other setting is preserved.

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

## Disclaimers

> [!CAUTION]
> This utility modifies power management state using SMC keys and process injection into system daemons (`PowerUIAgent`). It is provided as-is without warranty.
