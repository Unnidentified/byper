# forensic-agent-plan.md: engine & UI directive for macos-ch.bypass
Authoritative directive for any agent or developer working on this codebase.
Precedence: specific beats general. Reality beats this file for safety-critical decisions; conflicts must be recorded and amendments proposed. Silent deviation is a violation.

## 0. HOW TO READ THIS FILE
Read it in full before any tool action. First report line states which sections apply.
Every numbered constraint is mandatory; rationales guide edge cases but never override the rule.
Amendments happen only by editing this file between runs, never by improvising during one.

## 1. STRICT ISOLATION DIRECTIVE (UI vs. CORE ENGINE)
1. **Non-UI Tasks → Hands off UI:** When working on backend, engine, CLI, kernel/powerui internals, build/install scripts, or telemetry probes, DO NOT modify, reformat, redesign, or alter any UI components (SwiftUI views, layouts, fonts, colors, asset resolvers, menu dropdowns, spacing, status bar icons) in any way.
2. **UI Tasks → Hands off Core Engine:** When working on UI modifications, styling, layouts, animations, or visual polish, DO NOT touch, alter, or refactor internal core engine mechanics, backend power routing, SMC routines, or power management functions unless the UI task explicitly requires wiring to an internal function (e.g. connecting a new UI toggle or slider to an internal engine hook).
3. **Preserve Documentation & Comments:** Maintain documentation integrity and preserve all existing comments and docstrings across boundaries unless explicitly requested otherwise.

## 2. GLOSSARY
- **hold / bypass:** charging stopped at current SoC, AC runs the system directly, battery ~0 mA.
- **kick:** temporarilyEnableCharging / PowerUISmartChargeManager override, the call proven to resume charging in seconds.
- **lockout:** disabledUntilDate, timer armed by kicks; cleared by enableSmartCharging / in-process state reset.
- **plug cycle:** ExternalConnected false then true. Handled with state memory in companion app.
- **truth table:** section 6 register signatures. Single source of truth for hardware state.
- **NCR:** NotChargingReason. MoO: mode of operation (1 charging, 7 hold).
- **MCL:** maximum charge limit. OBC: optimized battery charging. DEoC: drain to end of charge.
- **top-off:** the final resume-to-100 phase; engageFrom from-date controls it.
- **engine:** src/powerui.m, src/power.c, src/smc.c, and installed CLI /usr/local/bin/byper.
- **companion GUI:** src/app/ (SwiftUI menu bar application `byper.app`).

## 3. PROJECT FACTS
- **Root:** /Users/gefaass/Desktop/Documents/agent stuff/macos-ch.bypass #2 (working copy; original lives at /Users/gefaass/Desktop/addon-modules/working/macos-ch.bypass #2)
- **Source Layout:**
  - `src/main.c`, `src/powerui.m` (PowerUI & LLDB bridge), `src/power.c`, `src/battery.c`, `src/smc.c`
  - `src/app/` (`AppDelegate.swift`, `BatteryDropdownView.swift`, `BatteryMonitor.swift`, `BatteryAssetResolver.swift`, `CLIEngineBridge.swift`, `ByperIntents.swift`)
  - `bin/byper` (native CLI binary), `byper.app` (menu bar companion app bundle)
  - `Makefile`, `install.sh`, `uninstall.sh`, completions (`_byper`, `_byp`, `byp.bash`)
- **Machine Target:** MacBook Pro (Apple Silicon M-series). Build floor is **macOS 11.0 Big Sur** (oldest release running Apple Silicon): Makefile compiles with `-target arm64-apple-macos11.0`, `Info.plist` carries `LSMinimumSystemVersion: 11.0`. Newer-API calls must be gated (`#available` / back-deploy shims for `tint`, `controlSize`, `kIOMainPortDefault`, `isLowPowerModeEnabled`, `NSHostingSizingOptions`).
- **Privilege Escalation:** SUID root on `/usr/local/bin/byper`, Touch ID / AppleScript helper on companion app install. SUID permissions must be preserved on any reinstall.
- **Installed Binaries:** `/usr/local/bin/byper` (symlinked as `byp` and `chbypass`), `/Applications/byper.app`.
- **State Files:** `/tmp/byp.state` (active hold marker). User logs and exported session CSVs on Desktop must never be deleted or modified.

## 4. MISSION
- `byper on` stops charging instantly at any SoC (verified across full battery range).
- `byper off` resumes fast charging to 100% without leaving state that blocks the next `on`.
- Toggling works reliably every time, survives terminal exit, never corrupts System Settings battery sliders.
- Menu Bar Companion app (`byper.app`) provides live telemetry, localized temperature, plug/display/threshold automations, caffeinate (IOPMAssertion display-sleep hold), per-app auto LPM, Travel/Docked presets with snapshot restore, a continuous master power slider (chronological row fade; full-off snapshots and disables everything), CSV session logging, global hotkey (Cmd+Opt+B), App Intents (macOS 13+), and a launch-time self-updater prompt — with near-zero CPU and RAM overhead.

## 5. HARD CONSTRAINTS (violation = revert, then report violation)
1. **Never persist an MCL below 100:** Do not leave `chargeLimitTargetSoC` permanently modified in defaults.
2. **Never signal powerd:** `killall -HUP powerd` or signaling powerd is forbidden (arms debounces and causes flapping).
3. **Never write SMC charge keys:** SMC registers on Apple Silicon are read-only telemetry. Writes return errors.
4. **Never fabricate:** Every pass claim must be backed by live verification commands and raw register output.
5. **Clean install & verify:** On rebuild, install to `/usr/local/bin/byper` and `/Applications/byper.app`, verify binary permissions (`4755` SUID root).
6. **No persistent system daemon fighting the OS:** No LaunchDaemons or background kernel services fighting powerd. GUI companion uses asynchronous background dispatch queues for lightweight IOKit/CLI polling without blocking the main UI thread.
7. **Snapshot before risky rewrites:** Always keep backups of project state before destructive refactors.
8. **No emoji in UI or CLI output.** Keep clean, professional monospace/system aesthetics.

## 6. HARDWARE TRUTH TABLE (Single Source of Truth)
- **hold (Bypass):** AC attached, IsCharging No, NCR `0x01000000`, |amps| < 100 mA.
- **charging:** AC attached, IsCharging Yes, NCR `0`, positive amperage (+500 to +3500 mA).
- **idle / full:** AC attached, NCR `0`, IsCharging No, |amps| <= 100 mA, SoC >= 95%.
- **on battery:** AC detached, negative amperage. Classify strictly by `acAttached`, never by description strings.
- **Sign handling:** Negative amperage can wrap as unsigned two's complement in raw registry dumps; parse as signed 16/32-bit integer.

## 7. PROBE-BEFORE-EDIT DOCTRINE
Unknown mechanisms or suspected hardware regressions must be verified with isolated scratch probes or live register dumps before modifying core codebase files. Never guess into main source.

## 8. REWIND AND CHECKPOINT DOCTRINE
If a change introduces unexpected regressions or crashes, immediately revert to the last verified clean state. Test and confirm hardware telemetry matches truth table before marking tasks complete.

## 9. COMPANION APP PITFALLS (verified regressions — do not reintroduce)
1. **SUID is load-bearing:** a non-SUID CLI prints `enabled [✓]` but the SMC write silently fails. After any reinstall/copy of `byper.app` or `/usr/local/bin/byper`, re-apply `chown root:wheel` + `chmod 4755`. Verify engage via `status` → `state: hold` + NCR `0x01000000`, never by exit code alone.
2. **`scaleEffect` keeps layout size:** switches scaled to 0.70 retain their full ~51pt layout footprint. Any inline row content (threshold %, transition timer) overflows unless the switch frame is clamped (`.frame(width: 36)` + offset to re-seat the visual edge).
3. **Popover refit subscriptions:** every expandable section flag must feed the `Publishers.Merge` in `AppDelegate.applicationDidFinishLaunching` (or rely on `NSHostingSizingOptions.preferredContentSize` on macOS 13+). Unsubscribed flags leave the popover stuck at expanded height on collapse.
4. **Run-loop modes:** `Timer.scheduledTimer` defaults to `.default` mode and stalls while menus track the cursor or the screen sleeps. Background/threshold timers must be added to `RunLoop.main` with `.common`.
5. **`setPowerMode` guards:** same-mode short-circuits and `isTransitioning` early-returns can wedge on stale state and silently swallow enable/disable. Every toggle must issue a real CLI round-trip (restored from the working backup baseline).
6. **Preset snapshots:** fresh preset activations must start from factory defaults — clear the stored snapshot on activate; the Combine capture pipeline only records manual changes made while the mode is active.
