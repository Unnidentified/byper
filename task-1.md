# TASK 1: Implement Per-App Automatic Low Power Mode (Power Save) in `macos-ch.bypass`

## Project Context
`macos-ch.bypass` is a native macOS status bar companion app built with Swift (AppKit + SwiftUI) and a C CLI backend (`byper`).
- **Core State Monitor:** `src/app/BatteryMonitor.swift` (`@ObservableObject`)
- **UI Dropdown:** `src/app/BatteryDropdownView.swift` (SwiftUI popover)
- **CLI / OS Bridge:** `src/app/CLIEngineBridge.swift` (manages `pmset` / Low Power Mode calls)
- **Project Rule:** Follow `forensic-agent-plan.md` strictly. Maintain the clean monospace dark UI theme (`FiraCode` font, `CheckmarkToggleStyle`, fixed popover width: `242`), and do not touch unrelated bypass engine routines.

---

## Objective
Implement a feature that automatically engages macOS Low Power Mode (Battery Saver) when specific user-selected applications gain window focus, and disables it when focusing out to non-selected applications.

---

## Detailed Requirements & Implementation Plan

### 1. UI: Dropdown & Scrollable App Selector (`BatteryDropdownView.swift`)
1. **Conditional Visibility:**
   - On the **Power Save / Low Power Mode** row, display a small expandable dropdown toggle/icon.
   - This dropdown trigger must be visible **ONLY when the global Battery Saver toggle is currently OFF** (`!monitor.isLowPowerMode`).
2. **Scrollable App Picker:**
   - Clicking the trigger smoothly expands a compact list of installed applications.
   - **Height constraint:** Must use a `ScrollView` with a capped `frame(maxHeight: 160)` and `.fixedSize(horizontal: true, vertical: false)` so it scrolls neatly without blowing out the menu height.
   - **List Items:** Each item should show the app's native small icon (`NSWorkspace.shared.icon(forFile:)`), the app name, and a toggle/checkmark using `CheckmarkToggleStyle`.
   - **Quick Sorting:** Sorted alphabetical list of apps discovered in `/Applications` and `/System/Applications`.

### 2. Backend Engine: Active Window Focus Observer (`BatteryMonitor.swift`)
1. **Installed App Discovery:**
   - Asynchronously discover user-installed `.app` bundles from `/Applications` and `/System/Applications` (or `NSWorkspace.shared.runningApplications`) in a background queue on startup/first expansion, caching them in `@Published var installedApps: [InstalledAppInfo] = []` to prevent any UI freezing.
2. **Persistence:**
   - Store selected bundle identifiers in `UserDefaults` under key `byp_auto_lpm_bundle_ids` (as a `Set<String>`).
3. **Event-Driven Window Focus Tracking (Zero CPU Polling):**
   - In `BatteryMonitor.swift`, subscribe to `NSWorkspace.didActivateApplicationNotification` using `NSWorkspace.shared.notificationCenter`.
   - When a notification arrives:
     1. Retrieve the frontmost application's bundle identifier (`NSRunningApplication.bundleIdentifier`).
     2. Check if the active app is in the user's enabled bundle ID set.
     3. If the focused app is in the list and LPM is not active: automatically engage Low Power Mode via `CLIEngineBridge.setLowPowerMode(enabled: true)` and mark an internal flag `isAutoLPMTriggered = true`.
     4. When switching to any app NOT in the list: if `isAutoLPMTriggered` is `true`, automatically disengage Low Power Mode via `CLIEngineBridge.setLowPowerMode(enabled: false)` and reset the flag.
     5. If the user *manually* toggles global Battery Saver ON, disable the auto-switching behavior until manual mode is turned back OFF.

### 3. Build & Verification
1. Verify compilation via `make app` and test running the installed app.
2. Confirm switching between an assigned app (e.g. Brave Browser) and another app (e.g. Terminal / Finder) flips Low Power Mode ON and OFF seamlessly in real time without UI stutter or CPU spikes.
