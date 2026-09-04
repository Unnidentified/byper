//
// ByperIntents.swift
// App Intents bridge: exposes bypass + preset controls to Shortcuts / Spotlight.
// Built with swiftc (no appintentsmetadataprocessor in CLT), so Shortcuts discovery
// may require a full Xcode build; the CLI (`byp on|off|t`) remains the guaranteed path.
//

import AppKit
import AppIntents

@available(macOS 13.0, *)
private func byperMonitor() -> BatteryMonitor? {
    (NSApplication.shared.delegate as? AppDelegate)?.monitor
}

@available(macOS 13.0, *)
struct BypassOnIntent: AppIntent {
    static var title: LocalizedStringResource = "Enable Bypass Charging"
    static var description = IntentDescription("Hold the battery at its current charge and run directly from AC.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let monitor = byperMonitor() else {
            return .result(dialog: "byper is not running")
        }
        guard monitor.isPluggedIn else {
            return .result(dialog: "Connect the charger to engage bypass")
        }
        monitor.setPowerMode(.bypass)
        return .result(dialog: "Bypass engaged at \(monitor.percentage)%")
    }
}

@available(macOS 13.0, *)
struct BypassOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Charging"
    static var description = IntentDescription("Release the bypass hold and resume fast charging to 100%.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let monitor = byperMonitor() else {
            return .result(dialog: "byper is not running")
        }
        monitor.setPowerMode(.charging)
        return .result(dialog: "Charging resumed")
    }
}

@available(macOS 13.0, *)
struct ToggleBypassIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Bypass Charging"
    static var description = IntentDescription("Switch between bypass hold and normal charging.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let monitor = byperMonitor() else {
            return .result(dialog: "byper is not running")
        }
        let next: BatteryMonitor.PowerMode = monitor.powerMode == .bypass ? .charging : .bypass
        monitor.setPowerMode(next)
        return .result(dialog: next == .bypass ? "Bypass engaged" : "Charging resumed")
    }
}

@available(macOS 13.0, *)
struct ApplyTravelPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Travel Preset"
    static var description = IntentDescription("Powersave on and Caffeinate always-on.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let monitor = byperMonitor() else {
            return .result(dialog: "byper is not running")
        }
        monitor.activatePreset(.travel)
        return .result(dialog: "Travel preset activated")
    }
}

@available(macOS 13.0, *)
struct ApplyDeskPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Docked Preset"
    static var description = IntentDescription("Bypass when the charger is connected, and auto-caffeinate on bypass.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let monitor = byperMonitor() else {
            return .result(dialog: "byper is not running")
        }
        monitor.activatePreset(.docked)
        return .result(dialog: "Docked preset activated")
    }
}