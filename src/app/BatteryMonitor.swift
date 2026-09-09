//
// BatteryMonitor.swift
// Native macOS Battery Menu Bar Companion App
//

import Foundation
import AppKit
import SwiftUI
import Combine
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement

struct InstalledAppInfo: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let path: String
    var id: String { bundleID }
}

final class BatteryMonitor: ObservableObject {
    enum PowerMode: String, CaseIterable, Codable {
        case charging = "charging"
        case bypass = "bypass"
    }
    
    @Published var powerMode: PowerMode = PowerMode(rawValue: UserDefaults.standard.string(forKey: "byp_power_mode") ?? "charging") ?? .charging {
        didSet {
            UserDefaults.standard.set(powerMode.rawValue, forKey: "byp_power_mode")
        }
    }
    // Engine-confirmed mode: drives the status-bar icon and waits for the CLI apply.
    // powerMode is UI-facing and flips instantly on slider passes.
    @Published var appliedPowerMode: PowerMode = PowerMode(rawValue: UserDefaults.standard.string(forKey: "byp_power_mode") ?? "charging") ?? .charging
    private var pendingEngineApply = false
    // Master-slider drag state: while the mouse is held, bypass changes are UI-only;
    // the real engine switch fires on release (finishMasterDrag()).
    var isDraggingMaster = false
    private var pendingDragPowerMode: PowerMode?
    // Graph counter: counts up while a bypass switch is in flight, snaps back to 0.00s on apply.
    @Published var counterValue: Double = 0
    @Published var counterCounting: Bool = false
    private var counterStart = Date()
    private var counterTicker: Timer?
    // Apps actually visible (and checkable) in the Powersave dropdown that are checked.
    // autoLPMBundleIds can hold stale IDs of uninstalled apps — those must not light the row.
    var checkedVisibleApps: Int {
        installedApps.filter { autoLPMBundleIds.contains($0.id) }.count
    }
    @Published var targetPowerMode: PowerMode? = nil
    
    @Published var percentage: Int = (UserDefaults.standard.integer(forKey: "byp_cached_pct") != 0) ? UserDefaults.standard.integer(forKey: "byp_cached_pct") : 100
    @Published var isCharging: Bool = UserDefaults.standard.bool(forKey: "byp_cached_charging")
    @Published var isPluggedIn: Bool = (UserDefaults.standard.object(forKey: "byp_cached_plugged") != nil) ? UserDefaults.standard.bool(forKey: "byp_cached_plugged") : true
    @Published var isHold: Bool = UserDefaults.standard.bool(forKey: "byp_cached_hold")
    @Published var powerSourceTitle: String = "Battery Power"
    @Published var isLowPowerMode: Bool = false
    @Published var highEnergyApps: [String] = []

    // Per-App Auto Low Power Mode state
    @Published var installedApps: [InstalledAppInfo] = []
    @Published var isAppPickerExpanded: Bool = false
    @Published var autoLPMBundleIds: Set<String> = BatteryMonitor.loadAutoLPMBundleIds() {
        didSet {
            if autoLPMBundleIds != oldValue {
                UserDefaults.standard.set(Array(autoLPMBundleIds), forKey: "byp_auto_lpm_bundle_ids")
            }
        }
    }
    var isManualLowPowerMode: Bool = false
    var isAutoLPMTriggered: Bool = false

    // Auto Bypass at Threshold state
    @Published var isThresholdMenuExpanded: Bool = false
    @Published var isCaffeineMenuExpanded: Bool = false
    @Published var isSlowChargeMenuExpanded: Bool = false
    @Published var isBypassOptionsExpanded: Bool = false
    // Quit hook: resume charging so the machine is not left bypassing with no UI running
    @Published var disableBypassOnQuit: Bool = UserDefaults.standard.bool(forKey: "byp_disable_bypass_on_quit") {
        didSet {
            UserDefaults.standard.set(disableBypassOnQuit, forKey: "byp_disable_bypass_on_quit")
        }
    }
    @Published var autoBypassThresholdEnabled: Bool = UserDefaults.standard.bool(forKey: "byp_auto_bypass_threshold_enabled") {
        didSet {
            UserDefaults.standard.set(autoBypassThresholdEnabled, forKey: "byp_auto_bypass_threshold_enabled")
            if autoBypassThresholdEnabled {
                checkAutoBypassThreshold()
            }
        }
    }
    @Published var autoBypassThreshold: Int = {
        let stored = UserDefaults.standard.integer(forKey: "byp_auto_bypass_threshold")
        return (10...90).contains(stored) ? stored : 40
    }() {
        didSet {
            UserDefaults.standard.set(autoBypassThreshold, forKey: "byp_auto_bypass_threshold")
            checkAutoBypassThreshold()
        }
    }
    private var thresholdSnoozed = false

    // Slow Charge: duty-cycled burst charging. SMC charge-rate keys are read-only on
    // Apple Silicon (probed: CHBI write rejected), so a slow net rate is achieved by
    // alternating between hold (0 mA) and charging bursts. Net rate ≈ burst rate ×
    // burstFraction. Persisted; re-arms on plug/mode changes via the pipelines below.
    // USER BYPASS ALWAYS WINS: appliedPowerMode == .bypass (set only by user actions,
    // never by the 4s reconcile) suspends the cycle; reconcile-driven powerMode flips
    // during the rest phase are ignored so the cycle can't self-cancel.
    @Published var slowChargeEnabled: Bool = UserDefaults.standard.bool(forKey: "byp_slow_charge_enabled") {
        didSet {
            #if VANILLA
            // Vanilla build: Slow Charge is not offered (known issue where the
            // duty cycle re-engages bypass after some time). Force the flag off
            // so no stale persisted state can ever arm the cycle.
            if slowChargeEnabled {
                slowChargeEnabled = false
                UserDefaults.standard.set(false, forKey: "byp_slow_charge_enabled")
            }
            #else
            // Only one or another: refuse to enable Slow Charge while Bypass is
            // engaged OR still applying (the multi-second LLDB window, during
            // which powerMode/appliedPowerMode have not flipped yet).
            if slowChargeEnabled && bypassActiveOrPending {
                slowChargeEnabled = false
                return
            }
            #endif
            UserDefaults.standard.set(slowChargeEnabled, forKey: "byp_slow_charge_enabled")
            updateSlowChargeCycle()
        }
    }
    // "Always On": the cycle keeps governing the charger whenever plugged and not
    // bypassing — including at full battery (holds it instead of letting macOS
    // idle top-off charge it). Without it the cycle stands down at 100%.
    // Mutually exclusive with "Off on exit": enabling one while the other is on
    // is REFUSED at the model level (the UI lock is cosmetic only — custom
    // ToggleStyle bodies do not reliably honor .disabled()).
    @Published var slowChargeAlwaysOn: Bool = UserDefaults.standard.bool(forKey: "byp_slow_charge_always") {
        didSet {
            if slowChargeAlwaysOn && slowChargeOffOnExit {
                slowChargeAlwaysOn = false // refuse: the other option is active
                return
            }
            UserDefaults.standard.set(slowChargeAlwaysOn, forKey: "byp_slow_charge_always")
            updateSlowChargeCycle()
        }
    }
    // "Off on exit": quitting the app resumes normal charging instead of leaving
    // a rest-phase hold in place. Same mutual exclusion, enforced here too.
    @Published var slowChargeOffOnExit: Bool = UserDefaults.standard.bool(forKey: "byp_slow_charge_off_exit") {
        didSet {
            if slowChargeOffOnExit && slowChargeAlwaysOn {
                slowChargeOffOnExit = false // refuse: the other option is active
                return
            }
            UserDefaults.standard.set(slowChargeOffOnExit, forKey: "byp_slow_charge_off_exit")
        }
    }
    // Seconds charging per cycle (burst) vs seconds holding per cycle (rest).
    // 20s on / 40s off with a ~2.4A burst ≈ 0.8A net ≈ 10W — "slow charger" pace.
    private let slowBurstSeconds: TimeInterval = 20
    private let slowRestSeconds: TimeInterval = 40
    private enum SlowPhase { case idle, burst, rest }
    private var slowPhase: SlowPhase = .idle
    private var slowCycleTimer: Timer?
    var slowChargeCycleActive: Bool { slowPhase != .idle }

    private func updateSlowChargeCycle() {
        let wasResting = slowPhase == .rest
        slowCycleTimer?.invalidate()
        slowCycleTimer = nil
        let userBypass = appliedPowerMode == .bypass
        let fullStandDown = !slowChargeAlwaysOn && percentage >= 100
        guard slowChargeEnabled, isPluggedIn, !isTransitioning, !userBypass, !fullStandDown else {
            // Stand down: if the cycle left a rest hold engaged and bypass isn't
            // the reason we're stopping, hand the charger back (full-rate charge).
            if wasResting && !userBypass {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard self != nil else { return }
                    _ = CLIEngineBridge.disableHoldSync()
                }
            }
            slowPhase = .idle
            return
        }
        startSlowBurst()
    }

    private func startSlowBurst() {
        // A hold we don't own (user bypass via appliedPowerMode, or an automation
        // engage) must never be overridden by a burst. Our own rest hold is fine.
        guard slowChargeEnabled, isPluggedIn, appliedPowerMode != .bypass, !isHold || slowPhase == .rest else {
            slowPhase = .idle
            return
        }
        slowPhase = .burst
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = CLIEngineBridge.disableHoldSync() // burst: charge at full rate
        }
        let t = Timer(timeInterval: slowBurstSeconds, repeats: false) { [weak self] _ in
            self?.startSlowRest()
        }
        RunLoop.main.add(t, forMode: .common)
        slowCycleTimer = t
    }

    private func startSlowRest() {
        // Bypass engaged mid-burst: it owns the charger (already holding); stand down silently.
        guard slowChargeEnabled, isPluggedIn, appliedPowerMode != .bypass else {
            slowPhase = .idle
            return
        }
        slowPhase = .rest
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = CLIEngineBridge.enableHoldSync() // rest: hold at current SoC
        }
        let t = Timer(timeInterval: slowRestSeconds, repeats: false) { [weak self] _ in
            self?.startSlowBurst()
        }
        RunLoop.main.add(t, forMode: .common)
        slowCycleTimer = t
    }


    private var focusObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?
    private var hasLoadedInstalledApps = false
    private var isDiscoveringApps = false
    private var autoLPMReconcileTimer: Timer?
    private var appIconCache: [String: NSImage] = [:]

    static func loadAutoLPMBundleIds() -> Set<String> {
        if let ids = UserDefaults.standard.object(forKey: "byp_auto_lpm_bundle_ids") as? Set<String> {
            return ids
        }
        if let ids = UserDefaults.standard.array(forKey: "byp_auto_lpm_bundle_ids") as? [String] {
            return Set(ids)
        }
        return []
    }
    
    @Published var temperature: Double = 32.0
    @Published var temperatureHistory: [Double] = []
    @Published var adapterInfo: String = ""
    @Published var currentWatts: Double = 0.0
    
    @Published var isTransitioning: Bool = false
    @Published var transitionStartTime: Date? = nil
    @Published var transitionElapsed: TimeInterval = 0
    private var transitionTicker: Timer?
    @Published var transitionEndTime: Date? = nil
    @Published var transitionMessage: String = ""
    @Published var isPopoverVisible: Bool = false
    @Published var exportMessage: String = ""
    @Published var isHoveringSettings: Bool = false
    
    // Live Background Log Recording State
    @Published var isRecordingLog: Bool = false
    @Published var recordingDurationSec: Int = 0
    @Published var recordedSampleCount: Int = 0
    
    // Automation Preferences
    @Published var isBypassMenuExpanded: Bool = false
    @Published var showLoggerInfo: Bool = false
    @Published var wavePhase: Double = 0.0
    private var lastWaveTime: TimeInterval = 0.0
    @Published var autoHoldOnPlug: Bool = UserDefaults.standard.bool(forKey: "byp_auto_hold_on_plug") {
        didSet {
            UserDefaults.standard.set(autoHoldOnPlug, forKey: "byp_auto_hold_on_plug")
        }
    }
    @Published var autoHoldOnDisplay: Bool = {
        if UserDefaults.standard.object(forKey: "byp_auto_hold_on_display") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "byp_auto_hold_on_display")
    }() {
        didSet {
            UserDefaults.standard.set(autoHoldOnDisplay, forKey: "byp_auto_hold_on_display")
        }
    }
    @Published var lastHoldPriorToUnplug: Bool = false
    @Published var autoHoldAtLogin: Bool = UserDefaults.standard.bool(forKey: "byp_auto_hold_at_login") {
        didSet {
            UserDefaults.standard.set(autoHoldAtLogin, forKey: "byp_auto_hold_at_login")
        }
    }
    @Published var autoCaffeineOnBypass: Bool = UserDefaults.standard.bool(forKey: "byp_auto_caffeine_on_bypass") {
        didSet {
            UserDefaults.standard.set(autoCaffeineOnBypass, forKey: "byp_auto_caffeine_on_bypass")
        }
    }
    @Published var caffeineAlwaysOn: Bool = UserDefaults.standard.bool(forKey: "byp_caffeine_always_on") {
        didSet {
            UserDefaults.standard.set(caffeineAlwaysOn, forKey: "byp_caffeine_always_on")
        }
    }
    // Master slider (0.0 = everything off, 1.0 = fully on). Dragging it down fades the
    // menu rows out chronologically and disables each feature as the knob passes its
    // row; sliding back up over a row restores the state it had when it was disabled.
    @Published var masterLevel: Double = {
        if UserDefaults.standard.object(forKey: "byp_master_level") == nil { return 1.0 }
        return min(max(UserDefaults.standard.double(forKey: "byp_master_level"), 0), 1)
    }() {
        didSet {
            UserDefaults.standard.set(masterLevel, forKey: "byp_master_level")
            masterLevelMoved = true
            handleMasterRowCrossings(oldValue: oldValue)
        }
    }
    var masterEnabled: Bool { masterLevel >= 0.999 }
    // Drag direction for the knob animation: spring bounce upward, plain ease downward
    @Published var masterLevelRising: Bool = true

    func setMasterLevel(_ newLevel: Double) {
        let clamped = min(max(newLevel, 0), 1)
        masterLevelRising = clamped >= masterLevel
        masterLevel = clamped
    }

    // Mouse release on the master slider: apply whatever bypass state the drag left pending.
    func finishMasterDrag() {
        isDraggingMaster = false
        guard let desired = pendingDragPowerMode else { return }
        pendingDragPowerMode = nil
        if desired != appliedPowerMode {
            setPowerMode(desired, blocksUI: false)
        }
    }

    // Quit button: capture the live bypass state, hand the charger back to macOS
    // (the status icon stops showing our hold), then terminate. The captured flag
    // re-engages bypass at the next launch — quitting never leaves effects running.
    func saveStateAndQuit() {
        let wasBypassing = isPluggedIn && (isHold || appliedPowerMode == .bypass || powerMode == .bypass)
        UserDefaults.standard.set(wasBypassing, forKey: "byp_resume_bypass_on_launch")
        if wasBypassing {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = CLIEngineBridge.disableHoldSync()
            }
        }
        NSApplication.shared.terminate(nil)
    }
    // Per-row master-slider cutoffs: knob position (1 - level) over the menu body
    // disables each feature as it passes down and restores it sliding back up.
    #if VANILLA
    static let masterRowOrder = ["bypass", "lpm", "caffeine", "settings"]
    #else
    static let masterRowOrder = ["presets", "bypass", "lpm", "threshold", "caffeine", "slowcharge", "settings"]
    #endif
    static func masterRowBoundary(_ key: String) -> Double {
        switch key {
        #if VANILLA
        case "bypass": return 0.20
        case "lpm": return 0.45
        case "caffeine": return 0.70
        case "settings": return 0.90
        #else
        case "presets": return 0.30
        case "bypass": return 0.10
        case "lpm": return 0.30
        case "threshold": return 0.50
        case "caffeine": return 0.70
        case "slowcharge": return 0.80
        case "settings": return 0.90
        #endif
        default: return 1.1
        }
    }
    private var masterRowFractions: [String: Double] = [:]
    // Enclosure vertical bounds in masterZone space (probed live) — the master
    // rail clamps itself to exactly these so it never overhangs the enclosure.
    @Published var masterEnclosureTop: CGFloat = 0
    @Published var masterEnclosureBottom: CGFloat = 0
    private var masterLevelMoved = false
    func rowBoundaryFraction(_ key: String) -> Double {
        masterRowFractions[key] ?? Self.masterRowBoundary(key)
    }
    // 0 → the fade line just touched the row's top, 1 → fully passed (matches the mask band).
    func rowFadeProgress(_ key: String) -> Double {
        let p = 1 - masterLevel
        return min(max((p - (rowBoundaryFraction(key) - 0.02)) / 0.04, 0), 1)
    }
    func masterRowEnabled(_ key: String) -> Bool {
        (1 - masterLevel) < rowBoundaryFraction(key)
    }
    // Row mid-points measured live from the menu layout (fraction of the enclosure
    // height, the same mapping the grey fade line uses) so switches flip exactly
    // when the line reaches them, whatever sections are expanded.
    func updateMasterRowGeometry(_ ys: [String: CGFloat]) {
        guard let h = ys["::height"], h > 1 else { return }
        // Enclosure bounds drive the master rail's vertical clamping (published so
        // MasterPowerSwitch re-renders when expandable rows change the height).
        if let t = ys["::enctop"], let b = ys["::encbottom"], b > t {
            if masterEnclosureTop != t { masterEnclosureTop = t }
            if masterEnclosureBottom != b { masterEnclosureBottom = b }
        }
        var changed = false
        for key in Self.masterRowOrder {
            if let y = ys[key] {
                let f = min(max(Double(y) / Double(h), 0.001), 0.999)
                if masterRowFractions[key] != f { masterRowFractions[key] = f; changed = true }
            }
        }
        guard changed, masterLevelMoved else { return }
        let p = 1 - masterLevel
        for key in Self.masterRowOrder {
            setRowDisabled(key, p >= rowBoundaryFraction(key))
        }
    }
    private func setRowDisabled(_ key: String, _ disabled: Bool) {
        let isDisabled = masterRowSnapshots[key] != nil
        if disabled && !isDisabled {
            disableMasterRow(key)
        } else if !disabled && isDisabled {
            restoreMasterRow(key)
        }
    }
    private struct MasterRowSnapshot {
        var bypass: PowerMode?
        var lpm: Bool?
        var threshold: Bool?
        var caffeineAlways: Bool?
        var caffeineAuto: Bool?
        var autoPlug: Bool?
        var autoLogin: Bool?
        var autoDisplay: Bool?
        var slowCharge: Bool?
    }
    private var masterRowSnapshots: [String: MasterRowSnapshot] = [:]

    private func handleMasterRowCrossings(oldValue: Double) {
        let pOld = 1 - oldValue, pNew = 1 - masterLevel
        guard pNew != pOld else { return }
        for key in Self.masterRowOrder {
            let f = rowBoundaryFraction(key)
            if pOld < f && pNew >= f {
                disableMasterRow(key)
            } else if pOld >= f && pNew < f {
                restoreMasterRow(key)
            }
        }
    }

    private func disableMasterRow(_ key: String) {
        var snap = masterRowSnapshots[key] ?? MasterRowSnapshot()
        switch key {
        case "slowcharge":
            if snap.slowCharge == nil { snap.slowCharge = slowChargeEnabled }
            withAnimation(.easeInOut(duration: 0.25)) { slowChargeEnabled = false }
        case "bypass":
            if snap.bypass == nil { snap.bypass = powerMode }
            withAnimation(.easeInOut(duration: 0.25)) {
                if isDraggingMaster {
                    // UI-only while the slider is held down; the engine switch fires on release
                    if powerMode != .charging { powerMode = .charging }
                    pendingDragPowerMode = .charging
                } else if isPluggedIn && (powerMode == .bypass || isHold) {
                    setPowerMode(.charging, blocksUI: false)
                } else if powerMode != .charging {
                    powerMode = .charging
                    appliedPowerMode = .charging
                }
            }
        case "lpm":
            if snap.lpm == nil { snap.lpm = isManualLowPowerMode || isLowPowerMode }
            if isManualLowPowerMode || isLowPowerMode {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isManualLowPowerMode = false
                    isLowPowerMode = false
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = CLIEngineBridge.setLowPowerModeSync(enabled: false)
                }
            }
        case "threshold":
            if snap.threshold == nil { snap.threshold = autoBypassThresholdEnabled }
            withAnimation(.easeInOut(duration: 0.25)) { autoBypassThresholdEnabled = false }
        case "caffeine":
            if snap.caffeineAlways == nil { snap.caffeineAlways = caffeineAlwaysOn }
            if snap.caffeineAuto == nil { snap.caffeineAuto = autoCaffeineOnBypass }
            withAnimation(.easeInOut(duration: 0.25)) {
                caffeineAlwaysOn = false
                autoCaffeineOnBypass = false
            }
        case "settings":
            if snap.autoPlug == nil { snap.autoPlug = autoHoldOnPlug }
            if snap.autoLogin == nil { snap.autoLogin = autoHoldAtLogin }
            if snap.autoDisplay == nil { snap.autoDisplay = autoHoldOnDisplay }
            withAnimation(.easeInOut(duration: 0.25)) {
                autoHoldOnPlug = false
                autoHoldAtLogin = false
                autoHoldOnDisplay = false
            }
        default:
            break
        }
        masterRowSnapshots[key] = snap
    }

    private func restoreMasterRow(_ key: String) {
        guard let snap = masterRowSnapshots.removeValue(forKey: key) else { return }
        switch key {
        case "slowcharge":
            if let v = snap.slowCharge { withAnimation(.easeInOut(duration: 0.25)) { slowChargeEnabled = v } }
        case "bypass":
            if snap.bypass == .bypass, isPluggedIn {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if isDraggingMaster {
                        if powerMode != .bypass { powerMode = .bypass }
                        pendingDragPowerMode = .bypass
                    } else {
                        setPowerMode(.bypass, blocksUI: false)
                    }
                }
            }
        case "lpm":
            if snap.lpm == true {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isManualLowPowerMode = true
                    isLowPowerMode = true
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = CLIEngineBridge.setLowPowerModeSync(enabled: true)
                }
            }
        case "threshold":
            if let t = snap.threshold { withAnimation(.easeInOut(duration: 0.25)) { autoBypassThresholdEnabled = t } }
        case "caffeine":
            withAnimation(.easeInOut(duration: 0.25)) {
                if let c = snap.caffeineAlways { caffeineAlwaysOn = c }
                if let c = snap.caffeineAuto { autoCaffeineOnBypass = c }
            }
        case "settings":
            withAnimation(.easeInOut(duration: 0.25)) {
                if let v = snap.autoPlug { autoHoldOnPlug = v }
                if let v = snap.autoLogin { autoHoldAtLogin = v }
                if let v = snap.autoDisplay { autoHoldOnDisplay = v }
            }
        default:
            break
        }
    }
    private var caffeineAssertionID: IOPMAssertionID = 0
    private var caffeineCancellable: AnyCancellable?
    var caffeineActive: Bool { caffeineAssertionID != 0 }

    private var runLoopSource: CFRunLoopSource?
    private var powerObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var displayObserver: NSObjectProtocol?
    private var activePollTimer: Timer?
    private var backgroundPollTimer: Timer?
    private var waveTimer: Timer?
    private var lastHoldPriorToSleep: Bool = false
    private var lastPluggedState: Bool = true
    private var lastTempBinTime: TimeInterval = 0
    
    // Persistent Session Recording Buffer
    private var logRecordingTimer: Timer?
    private var recordingStartTime: Date?
    private var sessionLogRecords: [String] = []

    init() {
        load24hTemperatureHistory()
        // App picker renders instantly from disk cache; restart kicks the background re-scan for newly installed apps
        installedApps = Self.loadCachedInstalledApps()
        hasLoadedInstalledApps = !installedApps.isEmpty
        refreshInstalledApps()
        updateLoginItem(enabled: true)
        refresh() // Full synchronous hardware probe before any UI is rendered
        registerNotification()
        
        lastPluggedState = isPluggedIn
        if autoHoldAtLogin && isPluggedIn && !isHold {
            engageAutoHoldOnPlug()
        }
        // Re-seed the last user request from hardware truth: a stale persisted
        // .bypass (app quit while bypassing, charger since resumed) must not
        // block automations like Slow Charge for the whole session.
        if isPluggedIn && appliedPowerMode == .bypass && !isHold && isCharging {
            appliedPowerMode = .charging
            powerMode = .charging
        }
        // Slow Charge owns the charger policy while enabled: automations yield to
        // it and its own switch is locked, so no legitimate bypass can exist —
        // any hold found at launch is a stale rest hold from a previous session.
        // Clear it and let the cycle take over, or it deadlocks the whole policy:
        // the reconcile reads the hold as user bypass, locks the Slow Charge
        // switch, and the cycle can never arm.
        if isPluggedIn && slowChargeEnabled && isHold {
            appliedPowerMode = .charging
            powerMode = .charging
            DispatchQueue.global(qos: .userInitiated).async {
                _ = CLIEngineBridge.disableHoldSync()
            }
        }
        // Bypass was active at last quit: the quit button disabled it for the
        // session; re-engage it now (never over Slow Charge — it owns the policy).
        if UserDefaults.standard.bool(forKey: "byp_resume_bypass_on_launch") {
            UserDefaults.standard.set(false, forKey: "byp_resume_bypass_on_launch")
            if isPluggedIn && !slowChargeEnabled {
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = CLIEngineBridge.enableHoldSync()
                }
                appliedPowerMode = .bypass
                powerMode = .bypass
            }
        }
        // Persisted Slow Charge must re-arm at launch (the didSet never fires for
        // the UserDefaults-seeded initial value). Also normalize the mutually
        // exclusive sub-options in case a stale build persisted both on.
        #if VANILLA
        if slowChargeEnabled {
            slowChargeEnabled = false
            UserDefaults.standard.set(false, forKey: "byp_slow_charge_enabled")
        }
        #else
        if slowChargeAlwaysOn && slowChargeOffOnExit {
            slowChargeOffOnExit = false
            UserDefaults.standard.set(false, forKey: "byp_slow_charge_off_exit")
        }
        #endif
        updateSlowChargeCycle()
        
        let notifName = Notification.Name("NSProcessInfoPowerStateDidChangeNotification")
        powerObserver = NotificationCenter.default.addObserver(
            forName: notifName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshIOKitOnly()
        }
        
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.autoHoldOnDisplay && self.isPluggedIn && NSScreen.screens.count > 1 {
                self.engageAutoHoldOnPlug()
            }
        }
        
        // Sleep / Wake Continuity Hook
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.lastHoldPriorToSleep && self.isPluggedIn {
                self.engageAutoHoldOnPlug()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.refreshIOKitOnly()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lastHoldPriorToSleep = (self?.isHold ?? false) && self?.slowPhase != .rest
        }
        
        // Per-App Auto Low Power Mode: event-driven window focus tracking (zero CPU polling)
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.reconcileAutoLPM()
        }

        // Deactivation fires the instant the configured app loses focus — react on it too so
        // disengaging is as fast as engaging (activation alone can race the window-server order)
        deactivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileAutoLPM()
        }
        
        // Gentle background polling timer to guarantee instant status bar updates even when popover is closed.
        // .common mode keeps it firing while menus are open or the screen is asleep —
        // the threshold trigger must work with the display off.
        let bgTimer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isPopoverVisible && !self.isTransitioning {
                self.refreshIOKitOnly()
            }
        }
        RunLoop.main.add(bgTimer, forMode: .common)
        backgroundPollTimer = bgTimer
        
        // Auto-LPM reconciler: closing/minimizing the last window keeps the app frontmost, so no
        // activation notification fires — reconcile frontmost-app window state on a light 1s tick
        let reconcileTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reconcileAutoLPM()
        }
        RunLoop.main.add(reconcileTimer, forMode: .common)
        autoLPMReconcileTimer = reconcileTimer

        // Auto Caffeine on Bypass: hold a PreventUserIdleDisplaySleep assertion while the
        // effective bypass state is active. One pipeline covers the UI toggle and every
        // automation (plug, display, login, threshold) plus unplug, since they all
        // mutate these published properties.
        // The auto path is EDGE-TRIGGERED: toggling "Auto Enable on Bypass" never enables
        // caffeinate by itself — it arms the auto-engagement for the next time bypass
        // engages. Only "Always" applies immediately.
        let bypassEngaged = Publishers.CombineLatest3($powerMode, $isHold, $isPluggedIn)
            .map { [weak self] mode, hold, plugged -> Bool in
                // A Slow Charge rest hold is not bypass: without this exclusion the
                // caffeine auto path would latch on every rest window and flap.
                plugged && (mode == .bypass || (hold && self?.slowPhase != .rest))
            }
            .removeDuplicates()
        caffeineCancellable = Publishers.CombineLatest(
                Publishers.CombineLatest($autoCaffeineOnBypass, bypassEngaged),
                $caffeineAlwaysOn
            )
            .scan((prevBypass: Bool?.none, latched: false, always: caffeineAlwaysOn)) { state, next in
                let (auto, bypass) = next.0
                let always = next.1
                guard let prev = state.prevBypass else {
                    // First emission seeds with the live bypass state: if bypass is
                    // ALREADY engaged when the user checks the box, that must not
                    // count as a rising edge — checking only arms the NEXT engagement.
                    return (prevBypass: Optional(bypass), latched: false, always: always)
                }
                var latched = state.latched
                if !auto {
                    latched = false
                } else if bypass && !prev {
                    latched = true   // rising edge of bypass engagement arms the auto path
                } else if !bypass {
                    latched = false
                }
                return (prevBypass: Optional(bypass), latched: latched, always: always)
            }
            .map { state -> Bool in
                var active = state.latched
                if state.always { active = true }
                if !self.isPluggedIn { active = false }
                return active
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.updateCaffeineAssertion(active: active)
            }

        // While a preset is active, every toggle change the user makes is saved into that mode
        let presetA = Publishers.CombineLatest4($powerMode, $autoBypassThresholdEnabled, $autoBypassThreshold, $autoCaffeineOnBypass)
        let presetB = Publishers.CombineLatest4($caffeineAlwaysOn, $autoHoldOnPlug, $autoHoldAtLogin, $autoHoldOnDisplay)
        presetCaptureCancellable = Publishers.CombineLatest3(presetA, presetB, $isLowPowerMode)
            .map { [weak self] _ -> (BatteryMonitor.Preset, PresetSnapshot)? in
                guard let self = self, self.masterEnabled, let active = self.activePreset else { return nil }
                return (active, PresetSnapshot(from: self))
            }
            .removeDuplicates { $0?.0 == $1?.0 && $0?.1 == $1?.1 }
            .sink { [weak self] pair in
                guard let self = self, let (active, snap) = pair else { return }
                self.presetSnapshots[active] = snap
                self.persistPresetSnapshots()
            }
    }

    func startActivePolling() {
        isPopoverVisible = true
        refresh()
        refreshEnergyApps()
        
        activePollTimer?.invalidate()
        // .common mode: keep polling while other menus track the cursor or the screen sleeps
        activePollTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isPopoverVisible, !self.isTransitioning else { return }
            self.refresh()
            self.refreshEnergyApps()
        }
        RunLoop.main.add(activePollTimer!, forMode: .common)
        
        // High-freq wave phase accumulator: 60fps, continuous regardless of speed changes
        waveTimer?.invalidate()
        lastWaveTime = Date().timeIntervalSinceReferenceDate
        let wt = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isPopoverVisible, self.masterEnabled else { return }
            let now = Date().timeIntervalSinceReferenceDate
            let dt = now - self.lastWaveTime
            self.lastWaveTime = now
            let base: Double = 1.3, fast: Double = 2.2
            let speed: Double
            if self.isTransitioning, let start = self.transitionStartTime {
                let elapsed = Date().timeIntervalSince(start)
                let t = min(elapsed / 0.8, 1.0)
                speed = base + (fast - base) * (t * t * t)
            } else if let end = self.transitionEndTime {
                let elapsed = Date().timeIntervalSince(end)
                if elapsed < 1.4 {
                    let t = elapsed / 1.4
                    let inv = 1.0 - t
                    speed = fast - (fast - base) * (1.0 - inv * inv * inv)
                } else {
                    speed = base
                }
            } else {
                speed = base
            }
            if dt > 0 && dt < 0.15 {
                self.wavePhase += dt * speed
            }
        }
        RunLoop.main.add(wt, forMode: .common)
        waveTimer = wt
    }

    func stopActivePolling() {
        isPopoverVisible = false
        activePollTimer?.invalidate()
        activePollTimer = nil
        waveTimer?.invalidate()
        waveTimer = nil
    }

    // MARK: - Persistent Background Telemetry Logger
    func startLogRecording() {
        guard !isRecordingLog else { return }
        isRecordingLog = true
        recordingStartTime = Date()
        recordingDurationSec = 0
        sessionLogRecords.removeAll()
        
        // Take initial snapshot
        recordSingleLogSample(elapsed: 0)
        recordedSampleCount = sessionLogRecords.count
        
        // Spawns background timer that persists across window close / open
        logRecordingTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecordingLog, let start = self.recordingStartTime else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            self.recordingDurationSec = elapsed
            self.recordSingleLogSample(elapsed: elapsed)
            self.recordedSampleCount = self.sessionLogRecords.count
        }
        RunLoop.main.add(timer, forMode: .common)
        logRecordingTimer = timer
    }

    func stopLogRecording() {
        guard isRecordingLog else { return }
        isRecordingLog = false
        logRecordingTimer?.invalidate()
        logRecordingTimer = nil
    }

    func resetLogRecording() {
        isRecordingLog = false
        logRecordingTimer?.invalidate()
        logRecordingTimer = nil
        recordingDurationSec = 0
        recordedSampleCount = 0
        sessionLogRecords.removeAll()
        exportMessage = "Reset [✓]"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.exportMessage == "Reset [✓]" {
                self?.exportMessage = ""
            }
        }
    }

    private func recordSingleLogSample(elapsed: Int) {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let tStr = timeFmt.string(from: Date())
        
        let status = CLIEngineBridge.getStatus()
        let amps = status?.amperage_mA ?? 0
        let temp = status?.temperature_C ?? self.temperature
        let watts = status?.wattage_W ?? self.currentWatts
        
        let stateStr: String
        let flowStr: String
        if self.isHold {
            stateStr = "Bypass (Hold)"
            flowStr = String(format: "%+d mA", amps)
        } else if self.isCharging {
            stateStr = "Fast Charging"
            flowStr = String(format: "%+d mA", amps)
        } else if self.isPluggedIn {
            stateStr = "AC Attached"
            flowStr = String(format: "%+d mA", amps)
        } else {
            stateStr = "On Battery"
            flowStr = String(format: "%+d mA", amps)
        }
        
        let powerStr = String(format: "%.1f W", abs(watts))
        let tempStr = String(format: "%.1f°C", temp)
        let elapsedStr = String(format: "+%02d:%02d", elapsed / 60, elapsed % 60)
        let battStr = "\(self.percentage)%"
        
        let line = "\(tStr),\(elapsedStr),\(battStr),\(stateStr),\(flowStr),\(powerStr),\(tempStr)"
        sessionLogRecords.append(line)
    }

    private func generateSystemHardwareHeader() -> [String] {
        var lines: [String] = []
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateStr = dateFormatter.string(from: Date())
        
        var model = "Mac"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var modelBuf = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &modelBuf, &size, nil, 0)
            model = String(cString: modelBuf)
        }
        
        var cpuBrand = "Apple Silicon"
        size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var cpuBuf = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &cpuBuf, &size, nil, 0)
            cpuBrand = String(cString: cpuBuf)
        }
        
        var osVersion = ""
        size = 0
        sysctlbyname("kern.osproductversion", nil, &size, nil, 0)
        if size > 0 {
            var osBuf = [CChar](repeating: 0, count: size)
            sysctlbyname("kern.osproductversion", &osBuf, &size, nil, 0)
            osVersion = String(cString: osBuf)
        }
        var osBuild = ""
        size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        if size > 0 {
            var buildBuf = [CChar](repeating: 0, count: size)
            sysctlbyname("kern.osversion", &buildBuf, &size, nil, 0)
            osBuild = String(cString: buildBuf)
        }
        let fullOs = "macOS \(osVersion) (Build \(osBuild))"
        
        let status = CLIEngineBridge.getStatus()
        let cycles = status?.cycleCount ?? 0
        let adInfo = adapterInfo.isEmpty ? (status?.adapterDesc ?? (isPluggedIn ? "USB-PD / MagSafe Charger" : "Unplugged (On Battery)")) : adapterInfo
        
        lines.append("BYPER POWER & BATTERY LOG,,,,,,")
        lines.append(String(format: "Timestamp: %@,,,,,,", dateStr))
        lines.append(String(format: "Mac Model: %@ (%d CPU Cores),,,,,,", model, ProcessInfo.processInfo.activeProcessorCount))
        lines.append(String(format: "Processor: %@,,,,,,", cpuBrand))
        lines.append(String(format: "Operating Sys: %@,,,,,,", fullOs))
        lines.append(String(format: "Battery Info: %d Charge Cycles,,,,,,", cycles))
        lines.append(String(format: "Power Adapter: %@,,,,,,", adInfo))
        lines.append(",,,,,,")
        lines.append("Time,Elapsed,Batt,Power State,Current Flow,Power Draw,Temp")
        return lines
    }

    func exportSessionLog(completion: @escaping (String?, Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "yyyyMMdd-HHmmss"
            let timeStamp = timeFmt.string(from: Date())
            let desktopUrl = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/tmp")
            let fileUrl = desktopUrl.appendingPathComponent("byper-session-\(timeStamp).csv")
            
            let headerLines = self.generateSystemHardwareHeader()
            var bodyLines: [String] = []
            
            if !self.sessionLogRecords.isEmpty {
                bodyLines = self.sessionLogRecords
            } else {
                let timeFmtSample = DateFormatter()
                timeFmtSample.dateFormat = "HH:mm:ss"
                let tStr = timeFmtSample.string(from: Date())
                let status = CLIEngineBridge.getStatus()
                let amps = status?.amperage_mA ?? 0
                let temp = status?.temperature_C ?? self.temperature
                let watts = status?.wattage_W ?? self.currentWatts
                let stateStr = self.isHold ? "Bypass (Hold)" : (self.isCharging ? "Fast Charging" : (self.isPluggedIn ? "AC Connected" : "On Battery"))
                let flowStr = (self.isHold || abs(amps) < 50) ? "0 mA (Resting)" : String(format: "%+d mA", amps)
                
                bodyLines.append("\(tStr),+00:00,\(self.percentage)%,\(stateStr),\(flowStr),\(String(format: "%.1f W", abs(watts))),\(String(format: "%.1f°C", temp))")
            }
            
            let fullContent = (headerLines + bodyLines + [
                ",,,,,,",
                String(format: "SUMMARY: %d samples recorded | Log File: %@", max(1, self.sessionLogRecords.count), fileUrl.lastPathComponent)
            ]).joined(separator: "\n") + "\n"
            
            do {
                try fullContent.write(to: fileUrl, atomically: true, encoding: .utf8)
                DispatchQueue.main.async {
                    completion(fileUrl.path, true)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, false)
                }
            }
        }
    }

    // Ultra-lightweight in-process IOKit query (0.0% CPU, no subprocess spawning)
    func refreshIOKitOnly() {
        var foundSmartBattery = false
        
        let matchDict = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, matchDict)
        if service != 0 {
            var propDict: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &propDict, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = propDict?.takeRetainedValue() as? [String: Any] {
                foundSmartBattery = true
                
                if let cur = dict["CurrentCapacity"] as? Int,
                   let max = dict["MaxCapacity"] as? Int, max > 0 {
                    self.percentage = Int((Double(cur) / Double(max)) * 100)
                }
                
                let extConn = dict["ExternalConnected"] as? Bool ?? false
                let isChargingRaw = dict["IsCharging"] as? Bool ?? false
                let amps = (dict["Amperage"] as? Int) ?? (dict["InstantAmperage"] as? Int) ?? 0
                
                var notChargingReason: UInt32 = 0
                var pmuConfigured: Int = 0
                var isChargingCD: Int = 0
                if let chargerData = dict["ChargerData"] as? [String: Any] {
                    notChargingReason = UInt32((chargerData["NotChargingReason"] as? Int) ?? 0)
                    pmuConfigured = (chargerData["PMUConfigured"] as? Int) ?? 0
                    isChargingCD = (chargerData["IsCharging"] as? Int) ?? 0
                }
                
                let nowPlugged = extConn
                if nowPlugged && !self.lastPluggedState {
                    self.isPluggedIn = true
                    // Charger connect alone must NOT engage bypass: only the explicit
                    // opt-in (autoHoldOnPlug) or the disconnect memory. The display
                    // automation lives in the screen-change observer — a docked
                    // display connecting fires it there; AC connecting does not.
                    if self.autoHoldOnPlug || self.lastHoldPriorToUnplug {
                        self.engageAutoHoldOnPlug()
                    }
                } else if !nowPlugged && self.lastPluggedState {
                    // A Slow Charge rest hold is ours, not user bypass — remembering
                    // it here made the next charger connect "restore" a bypass the
                    // user never toggled.
                    self.lastHoldPriorToUnplug = self.isHold && slowPhase != .rest
                }
                let wasPlugged = self.isPluggedIn
                self.lastPluggedState = nowPlugged
                self.isPluggedIn = nowPlugged
                if nowPlugged != wasPlugged { self.updateSlowChargeCycle() }
                
                if nowPlugged {
                    // At full battery a user-requested bypass shows as plain
                    // idle/full (NCR 0) — that IS the goal state, so with bypass
                    // intent set, full-idle counts as holding.
                    let fullIdle = percentage >= 95 && !isChargingRaw && abs(amps) < 100
                    let isBypassActive = (((notChargingReason & 0x01000000) != 0) && abs(amps) < 100 && !isChargingRaw) ||
                                         (appliedPowerMode == .bypass && fullIdle)
                    self.isHold = isBypassActive
                    
                    if isBypassActive || (notChargingReason & 0x01000000) != 0 || isChargingCD == 0 || !isChargingRaw || amps <= 0 {
                        self.isCharging = false
                    } else if notChargingReason == 0 && (pmuConfigured > 0 || isChargingCD == 1 || isChargingRaw) && amps > 0 {
                        self.isCharging = true
                    } else {
                        self.isCharging = isChargingRaw
                    }
                } else {
                    self.isHold = false
                    self.isCharging = false
                    self.isTransitioning = false
                    self.transitionStartTime = nil
                    self.transitionMessage = ""
                }
                
                if let tempRaw = (dict["BatteryData"] as? [String: Any])?["Temperature"] as? Int, tempRaw > 0 {
                    var c = (Double(tempRaw) / 100.0) - 273.15
                    if c < 0 || c > 100 {
                        c = Double(tempRaw) / 10.0
                    }
                    if c > 0 && c < 100 {
                        self.temperature = c
                        self.update24hTemperatureSample(c)
                    }
                }
            }
            IOObjectRelease(service)
        }
        
        if !foundSmartBattery {
            // Fallback to IOPS
            if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
               let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
                for ps in sources {
                    guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
                    if let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                       let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                        self.percentage = Int((Double(cur) / Double(max)) * 100)
                    }
                    self.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                    if let psState = desc[kIOPSPowerSourceStateKey] as? String {
                        let nowPlugged = (psState == kIOPSACPowerValue)
                        if nowPlugged && !self.lastPluggedState {
                            self.isPluggedIn = true
                            // Same rule as the IOKit path: charger connect alone
                            // never engages bypass — opt-in or disconnect memory only.
                            if self.autoHoldOnPlug || self.lastHoldPriorToUnplug {
                                self.engageAutoHoldOnPlug()
                            }
                        } else if !nowPlugged && self.lastPluggedState {
                            self.lastHoldPriorToUnplug = self.isHold && slowPhase != .rest
                        }
                        self.lastPluggedState = nowPlugged
                        self.isPluggedIn = nowPlugged
                        if !nowPlugged {
                            self.isHold = false
                            self.isCharging = false
                            self.isTransitioning = false
                    self.transitionStartTime = nil
                            self.transitionMessage = ""
                        }
                    }
                }
            }
        }
        
        if #available(macOS 12.0, *) {
            self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled || self.isAutoLPMTriggered
        } else {
            // macOS 11 has no public low-power query; manual + auto-LPM flags still drive the UI
            self.isLowPowerMode = self.isAutoLPMTriggered
        }
        checkAutoBypassThreshold()
        
        // Reconcile powerMode when plugged in (never during a pending slider-driven apply)
        if self.isPluggedIn && !pendingEngineApply && !isDraggingMaster {
            if self.isHold {
                // A Slow Charge rest hold is ours, not user bypass — don't let the
                // reconcile flip the bypass switch on during rest windows.
                if slowPhase != .rest && powerMode != .bypass {
                    powerMode = .bypass
                }
            } else if self.isCharging {
                if powerMode != .charging { powerMode = .charging }
            }
        }
        
        // Format Subtitle
        if !self.isPluggedIn {
            self.powerSourceTitle = "Battery Power"
            self.isHold = false
            self.isCharging = false
        } else if self.isHold || self.powerMode == .bypass {
            self.powerSourceTitle = "Power Adapter (Hold)"
        } else if self.isCharging {
            self.powerSourceTitle = "Power Adapter (Charging)"
        } else {
            self.powerSourceTitle = "Power Adapter (Full)"
        }
    }

    // Only one or another: true from the moment a bypass is requested (including
    // the multi-second CLI/LLDB apply window, when powerMode/appliedPowerMode
    // still read .charging) until it is disengaged.
    var bypassActiveOrPending: Bool {
        powerMode == .bypass || isHold || (isTransitioning && targetPowerMode == .bypass)
    }

    func setPowerMode(_ mode: PowerMode, blocksUI: Bool = true) {
        // Restored from the working backup: no same-mode short-circuit and no
        // isTransitioning guard — both could wedge on stale state and silently
        // swallow enable/disable. Every toggle issues a real CLI round-trip.
        // blocksUI=false (master-slider passes): the CLI round-trip still runs and
        // powerMode only flips on apply, but the transition UI/flag is skipped so
        // the slider is never frozen by the bypass milisec timer.
        guard isPluggedIn else { return }
        // Only one or another: bypass cannot engage while Slow Charge owns the
        // policy. Refused at the model so every caller (switch, master slider,
        // App Intents) is covered - the UI lock alone was bypassable during the
        // LLDB apply window.
        if mode == .bypass && slowChargeEnabled { return }

        counterStart = Date()
        startCounterTicker()
        if blocksUI {
            targetPowerMode = mode
            if mode == .charging {
                // Manual resume while below threshold: suppress threshold re-engage until SoC rises above it
                thresholdSnoozed = true
            }
            isTransitioning = true
            transitionStartTime = Date()
            transitionMessage = (mode == .bypass ? "Engaging bypass..." : "Resuming charging...")
            startTransitionTicker()
        } else {
            if mode == .charging { thresholdSnoozed = true }
            powerMode = mode  // UI flips instantly; status icon + counter wait for the apply
            pendingEngineApply = true
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = CLIEngineBridge.setPowerModeSync(mode)
            // C-level powerui already polled IOKit and confirmed the hardware state — no need to re-poll here
            DispatchQueue.main.async {
                self.powerMode = mode
                self.appliedPowerMode = mode
                // Never-both invariant: if a race latched Slow Charge while bypass
                // was applying, bypass wins and the flag clears.
                if mode == .bypass && self.slowChargeEnabled {
                    self.slowChargeEnabled = false
                }
                if blocksUI {
                    self.isTransitioning = false
                    self.transitionTicker?.invalidate()
                    self.transitionStartTime = nil
                    self.transitionEndTime = Date()
                    self.targetPowerMode = nil
                    self.transitionMessage = ""
                } else {
                    self.pendingEngineApply = false
                }
                self.updateSlowChargeCycle()
                self.refresh()
            }
        }
    }

    // MARK: - Presets (Travel / Docked — click to activate, click again to restore; long-press a name to rename)

    enum Preset: String, CaseIterable, Codable {
        case travel
        case docked
    }

    struct PresetSnapshot: Codable, Equatable {
        var powerModeRaw: String
        var lpmOn: Bool
        var thresholdEnabled: Bool
        var threshold: Int
        var caffeineAuto: Bool
        var caffeineAlways: Bool
        var autoOnPlug: Bool
        var autoAtLogin: Bool
        var autoOnDisplay: Bool

        init(from m: BatteryMonitor) {
            powerModeRaw = m.powerMode.rawValue
            lpmOn = m.isLowPowerMode
            thresholdEnabled = m.autoBypassThresholdEnabled
            threshold = m.autoBypassThreshold
            caffeineAuto = m.autoCaffeineOnBypass
            caffeineAlways = m.caffeineAlwaysOn
            autoOnPlug = m.autoHoldOnPlug
            autoAtLogin = m.autoHoldAtLogin
            autoOnDisplay = m.autoHoldOnDisplay
        }

        func apply(to m: BatteryMonitor) {
            let mode = BatteryMonitor.PowerMode(rawValue: powerModeRaw) ?? .charging
            if m.isPluggedIn {
                m.setPowerMode(mode)
            } else {
                m.powerMode = mode
                m.appliedPowerMode = mode
            }
            m.isManualLowPowerMode = lpmOn
            m.isLowPowerMode = lpmOn
            DispatchQueue.global(qos: .userInitiated).async {
                _ = CLIEngineBridge.setLowPowerModeSync(enabled: lpmOn)
            }
            m.autoBypassThresholdEnabled = thresholdEnabled
            m.autoBypassThreshold = threshold
            m.autoCaffeineOnBypass = caffeineAuto
            m.caffeineAlwaysOn = caffeineAlways
            m.autoHoldOnPlug = autoOnPlug
            m.autoHoldAtLogin = autoAtLogin
            m.autoHoldOnDisplay = autoOnDisplay
        }
    }

    // Neither mode is active on a fresh install
    @Published var activePreset: Preset? = {
        guard let raw = UserDefaults.standard.string(forKey: "byp_active_preset") else { return nil }
        return BatteryMonitor.Preset(rawValue: raw)
    }() {
        didSet {
            if let p = activePreset { UserDefaults.standard.set(p.rawValue, forKey: "byp_active_preset") }
            else { UserDefaults.standard.removeObject(forKey: "byp_active_preset") }
        }
    }
    // Rename state (long-press a mode name in the popover to edit it)
    @Published var renamingPreset: Preset? = nil
    @Published var renameText: String = ""

    private var presetSnapshots: [Preset: PresetSnapshot] = BatteryMonitor.loadPresetSnapshots()
    private var preActivationSnapshot: PresetSnapshot? = BatteryMonitor.loadPreActivationSnapshot()
    private var presetCaptureCancellable: AnyCancellable?

    private static func loadPresetSnapshots() -> [Preset: PresetSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: "byp_preset_snapshots"),
              let decoded = try? JSONDecoder().decode([Preset: PresetSnapshot].self, from: data) else { return [:] }
        return decoded
    }

    private static func loadPreActivationSnapshot() -> PresetSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: "byp_preset_pre_activation"),
              let decoded = try? JSONDecoder().decode(PresetSnapshot.self, from: data) else { return nil }
        return decoded
    }

    private func persistPresetSnapshots() {
        if let data = try? JSONEncoder().encode(presetSnapshots) {
            UserDefaults.standard.set(data, forKey: "byp_preset_snapshots")
        }
    }

    func togglePreset(_ preset: Preset) {
        if activePreset == preset {
            deactivatePreset()
        } else {
            activatePreset(preset)
        }
    }

    func activatePreset(_ preset: Preset) {
        // Remember the user's current setup so deactivating restores it exactly
        preActivationSnapshot = PresetSnapshot(from: self)
        if let data = try? JSONEncoder().encode(preActivationSnapshot) {
            UserDefaults.standard.set(data, forKey: "byp_preset_pre_activation")
        }
        activePreset = preset
        if let saved = presetSnapshots[preset] {
            saved.apply(to: self)
        } else {
            applyFactoryPreset(preset)
        }
        // A fresh activation starts from the factory defaults; only re-activating
        // after a manual customization (captured by the Combine pipeline) reuses them
        presetSnapshots[preset] = nil
        persistPresetSnapshots()
    }

    private func deactivatePreset() {
        activePreset = nil
        if let snap = preActivationSnapshot {
            snap.apply(to: self)
            preActivationSnapshot = nil
            UserDefaults.standard.removeObject(forKey: "byp_preset_pre_activation")
        }
    }

    // Factory defaults, used the first time a mode is activated (no saved customization yet)
    private func applyFactoryPreset(_ preset: Preset) {
        switch preset {
        case .travel:
            isManualLowPowerMode = true
            isLowPowerMode = true
            DispatchQueue.global(qos: .userInitiated).async {
                _ = CLIEngineBridge.setLowPowerModeSync(enabled: true)
            }
            caffeineAlwaysOn = true
        case .docked:
            autoCaffeineOnBypass = true
            if isPluggedIn {
                setPowerMode(.bypass)
            }
        }
    }

    func presetDisplayName(_ preset: Preset) -> String {
        UserDefaults.standard.string(forKey: "byp_preset_name_\(preset.rawValue)")
            ?? (preset == .travel ? "Travel" : "Docked")
    }

    func setPresetName(_ preset: Preset, _ name: String) {
        let key = "byp_preset_name_\(preset.rawValue)"
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == presetDisplayName(preset) {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
        objectWillChange.send()
    }

    // MARK: - Per-App Automatic Low Power Mode

    func loadInstalledAppsIfNeeded() {
        guard !hasLoadedInstalledApps, !isDiscoveringApps else { return }
        refreshInstalledApps()
    }

    // Restarts re-scan in background; list renders instantly from disk cache in the meantime
    private func refreshInstalledApps() {
        guard !isDiscoveringApps else { return }
        isDiscoveringApps = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = Self.scanInstalledApps()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDiscoveringApps = false
                self.hasLoadedInstalledApps = true
                guard !apps.isEmpty || self.installedApps.isEmpty else { return }
                self.installedApps = apps
                Self.persistInstalledApps(apps)
            }
        }
    }

    private static let installedAppsCacheKey = "byp_cached_installed_apps"

    private static func loadCachedInstalledApps() -> [InstalledAppInfo] {
        guard let raw = UserDefaults.standard.array(forKey: installedAppsCacheKey) as? [[String: String]] else { return [] }
        return raw.compactMap { dict in
            guard let bundleID = dict["bundleID"], let name = dict["name"], let path = dict["path"] else { return nil }
            return InstalledAppInfo(bundleID: bundleID, name: name, path: path)
        }
    }

    private static func persistInstalledApps(_ apps: [InstalledAppInfo]) {
        let raw = apps.map { ["bundleID": $0.bundleID, "name": $0.name, "path": $0.path] }
        UserDefaults.standard.set(raw, forKey: installedAppsCacheKey)
    }

    private static func scanInstalledApps() -> [InstalledAppInfo] {
        let fileManager = FileManager.default
        var seenBundleIDs = Set<String>()
        var apps: [InstalledAppInfo] = []
        for directory in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let path = directory + "/" + item
                guard let bundle = Bundle(url: URL(fileURLWithPath: path)),
                      let bundleID = bundle.bundleIdentifier,
                      seenBundleIDs.insert(bundleID).inserted else { continue }
                // Strict folder-visible name, exactly as listed in Finder
                let name = (item as NSString).deletingPathExtension
                apps.append(InstalledAppInfo(bundleID: bundleID, name: name, path: path))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // Auto-LPM counts a listed app as focused only while one of its windows is the frontmost
    // real window on screen. Clicking a menu bar icon, the desktop files or the wallpaper never
    // takes the front window away, so Battery Saver stays enabled through those.
    func reconcileAutoLPM() {
        guard !isManualLowPowerMode, !autoLPMBundleIds.isEmpty else { return }
        guard let ownerBundleID = Self.frontmostRealWindowOwnerBundleID() else {
            // No real window on screen at all (front window closed or minimized to a bare desktop)
            if isAutoLPMTriggered {
                isAutoLPMTriggered = false
                isLowPowerMode = false
                CLIEngineBridge.setLowPowerMode(enabled: false)
            }
            return
        }
        if autoLPMBundleIds.contains(ownerBundleID) {
            if !isLowPowerMode && !isAutoLPMTriggered {
                isAutoLPMTriggered = true
                isLowPowerMode = true
                CLIEngineBridge.setLowPowerMode(enabled: true)
            }
        } else if isAutoLPMTriggered {
            isAutoLPMTriggered = false
            isLowPowerMode = false
            CLIEngineBridge.setLowPowerMode(enabled: false)
        }
    }

    // Front-to-back scan for the first normal-level (layer 0) window with real bounds; its owner
    // holds the front window. Menu bar (24), status items (25), popovers and the desktop layer sit
    // outside layer 0 and are skipped.
    static func frontmostRealWindowOwnerBundleID() -> String? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, width > 0,
                  let height = bounds["Height"] as? Double, height > 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int,
                  let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                  let bundleID = app.bundleIdentifier else { continue }
            return bundleID
        }
        return nil
    }

    // Cached native icons: the picker re-renders with the 60fps wave timer while the popover is
    // open — NSWorkspace icon lookups per row per frame made scrolling janky
    func icon(for app: InstalledAppInfo) -> NSImage {
        if let cached = appIconCache[app.bundleID] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        appIconCache[app.bundleID] = icon
        return icon
    }

    // Auto Bypass at Threshold: engage hold once SoC drops to the configured threshold.
    // Manual resume snoozes the trigger until the battery climbs back above the threshold.
    func checkAutoBypassThreshold() {
        #if VANILLA
        // Vanilla build: the threshold automation is not offered (it currently
        // only engages while this switch is freshly toggled and has known
        // reliability issues). Stale persisted state must not auto-engage.
        if autoBypassThresholdEnabled {
            autoBypassThresholdEnabled = false
        }
        #else
        guard autoBypassThresholdEnabled, isPluggedIn else { return }
        // At/below threshold: clear any snooze and engage unless already holding.
        // (The old logic inverted this — it only engaged while ABOVE the threshold,
        // so the trigger never fired when the battery actually dropped.)
        guard percentage <= autoBypassThreshold else { return }
        guard !thresholdSnoozed, !isHold, !isTransitioning else { return }
        engageAutoHoldOnPlug()
        #endif
    }

    func engageAutoHoldOnPlug() {
        // Slow Charge owns the charger policy while enabled: no automation
        // (display, plug memory, wake, login, threshold) may engage bypass over
        // it. The cycle's rest holds are the only holds it should ever see.
        guard !slowChargeEnabled else { return }
        guard !isTransitioning else { return }
        isTransitioning = true
        // Declare the apply: bypassActiveOrPending must cover THIS window too,
        // or the Slow Charge switch stays unlocked while the hold is in flight
        // and both end up latched (the race that dimmed both switches).
        targetPowerMode = .bypass
        transitionStartTime = Date()
        transitionMessage = "Holding..."
        startTransitionTicker()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = CLIEngineBridge.enableHoldSync()
            let status = CLIEngineBridge.getStatus()
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let status = status {
                    let ncr = status.notChargingReason ?? 0
                    let amps = status.amperage_mA ?? 0
                    let isCharging = status.isCharging ?? false
                    self.isHold = self.isPluggedIn && ((status.holdActive == true) || ((ncr & 0x01000000) != 0 && abs(amps) < 50 && !isCharging))
                    self.isCharging = self.isPluggedIn && isCharging
                    if let pct = status.percentage { self.percentage = pct }
                } else {
                    self.isHold = self.isPluggedIn
                }
                
                if self.isPluggedIn {
                    if self.isHold {
                        self.powerSourceTitle = "Power Adapter (Hold)"
                        // The automation just engaged bypass: commit the mode now,
                        // or the toggle/icon read powerMode == .charging until the
                        // next IOKit reconcile flickers them off then on again.
                        self.powerMode = .bypass
                        self.appliedPowerMode = .bypass
                    } else if self.isCharging {
                        self.powerSourceTitle = "Power Adapter (Charging)"
                    } else {
                        self.powerSourceTitle = "Power Adapter (Full)"
                    }
                } else {
                    self.powerSourceTitle = "Battery Power"
                    self.isHold = false
                    self.isCharging = false
                }
                
                self.isTransitioning = false
                self.targetPowerMode = nil
                self.transitionTicker?.invalidate()
                self.transitionStartTime = nil
                self.transitionMessage = ""
                // Bypass won: if a race (enable during the apply window) left the
                // Slow Charge flag latched, clear it so the never-both invariant
                // holds in the persisted state, not just in the cycle guards.
                if self.isHold && self.slowChargeEnabled {
                    self.slowChargeEnabled = false
                }
            }
        }
    }

    // 30fps elapsed readout for the in-row transition timer (TimelineView needs macOS 14+)
    private func startTransitionTicker() {
        transitionTicker?.invalidate()
        transitionElapsed = 0
        let t0 = Date()
        let ticker = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isTransitioning else { return }
            self.transitionElapsed = Date().timeIntervalSince(t0)
            // Hard cap: if the apply never completes (CLI wedged, pipe held by a
            // grandchild, helper prompt dismissed), end the transition after 60 s
            // instead of counting forever. The user can re-toggle.
            if self.transitionElapsed > 60 {
                self.isTransitioning = false
                self.targetPowerMode = nil
                self.transitionStartTime = nil
                self.transitionMessage = ""
                self.transitionTicker?.invalidate()
                self.transitionTicker = nil
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        transitionTicker = ticker
    }

    // 30fps graph counter: counts up while a switch is in flight (including master-slider
    // passes, which skip the transition UI), then snaps back to 0.00s on apply.
    private func startCounterTicker() {
        counterTicker?.invalidate()
        counterCounting = true
        let t0 = counterStart
        let ticker = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isTransitioning || self.pendingEngineApply {
                self.counterValue = Date().timeIntervalSince(t0)
            } else {
                self.counterValue = 0
                self.counterCounting = false
                self.counterTicker?.invalidate()
                self.counterTicker = nil
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        counterTicker = ticker
    }

    // MARK: - Auto Caffeine (Prevent Display Sleep) while Bypass is active

    private func updateCaffeineAssertion(active: Bool) {
        if active {
            guard caffeineAssertionID == 0 else { return }
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "byper: bypass charging active" as CFString,
                &assertionID
            )
            if result == kIOReturnSuccess {
                caffeineAssertionID = assertionID
            }
        } else {
            guard caffeineAssertionID != 0 else { return }
            IOPMAssertionRelease(caffeineAssertionID)
            caffeineAssertionID = 0
        }
    }

    func refresh() {
        refreshIOKitOnly()
        
        // Query Unified CLI Engine for Hardware Bypass Hold State & Telemetry
        if let status = CLIEngineBridge.getStatus() {
            if let ac = status.acAttached {
                let wasPlugged = self.isPluggedIn
                self.isPluggedIn = ac
                if !ac {
                    // Mirror the IOKit unplug edge: record the hold BEFORE
                    // clearing it, or a CLI poll that wins the race erases the
                    // bypass memory and the replug never re-engages (the random
                    // "bypass forgotten" flip).
                    if wasPlugged {
                        self.lastHoldPriorToUnplug = self.isHold && self.slowPhase != .rest
                        self.lastPluggedState = false
                    }
                    self.isHold = false
                    self.isCharging = false
                } else if !wasPlugged {
                    // This poller saw the re-plug first: run the same connect
                    // edge as the IOKit path. lastPluggedState must be synced
                    // here too or BOTH pollers fire their edge independently.
                    self.lastPluggedState = true
                    if (self.autoHoldOnPlug || self.lastHoldPriorToUnplug) && !self.isTransitioning {
                        self.engageAutoHoldOnPlug()
                    }
                }
            }
            if let ch = status.isCharging {
                self.isCharging = self.isPluggedIn && ch
            }
            let ncr = status.notChargingReason ?? 0
            let holdActive = status.holdActive ?? false
            let amps = status.amperage_mA ?? 0
            self.isHold = self.isPluggedIn && (holdActive || ((ncr & 0x01000000) != 0 && abs(amps) < 50 && !self.isCharging))
            if let pct = status.percentage {
                self.percentage = pct
            }
            if let temp = status.temperature_C, temp > 0 {
                self.temperature = temp
                update24hTemperatureSample(temp)
            }
            if self.isPluggedIn, let adW = status.adapterWatts, adW > 0 {
                let v = Double(status.adapterVoltage_mV ?? 20000) / 1000.0
                let a = Double(status.adapterCurrent_mA ?? 2250) / 1000.0
                self.adapterInfo = String(format: "%.0fV @ %.2fA (%dW)", v, a, adW)
            } else if !self.isPluggedIn {
                let v = Double(status.voltage_mV ?? 12000) / 1000.0
                let w = status.wattage_W ?? 0.0
                self.adapterInfo = String(format: "%.1fW @ %.1fV", w, v)
            } else {
                self.adapterInfo = ""
            }
            
            self.currentWatts = status.wattage_W ?? 0.0
        } else {
            if !self.isPluggedIn {
                self.isHold = false
                self.isCharging = false
                self.adapterInfo = ""
            }
        }
        

    }
    
    private func load24hTemperatureHistory() {
        if let saved = UserDefaults.standard.array(forKey: "byp_24h_temp_history") as? [Double], saved.count == 24 {
            self.temperatureHistory = saved
        } else {
            let base = 32.0
            self.temperatureHistory = (0..<24).map { i in
                let hourVariation = sin(Double(i) / 24.0 * .pi * 2.0) * 0.8
                return base + hourVariation
            }
            save24hTemperatureHistory()
        }
        lastTempBinTime = Date().timeIntervalSince1970
    }
    
    private func update24hTemperatureSample(_ temp: Double) {
        let now = Date().timeIntervalSince1970
        guard !temperatureHistory.isEmpty else {
            temperatureHistory = Array(repeating: temp, count: 24)
            return
        }
        
        var history = temperatureHistory
        let lastIdx = history.count - 1
        history[lastIdx] = (0.02 * temp) + (0.98 * history[lastIdx])
        
        if now - lastTempBinTime >= 3600 {
            history.removeFirst()
            history.append(temp)
            lastTempBinTime = now
            save24hTemperatureHistory()
        }
        
        self.temperatureHistory = history
    }
    
    private func save24hTemperatureHistory() {
        UserDefaults.standard.set(temperatureHistory, forKey: "byp_24h_temp_history")
    }
    
    func refreshEnergyApps() {
        guard isPopoverVisible else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = CLIEngineBridge.fetchHighEnergyApps()
            DispatchQueue.main.async {
                self?.highEnergyApps = apps
            }
        }
    }

    private func updateLoginItem(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Gracefully handled
            }
        }
    }

    private func registerNotification() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        runLoopSource = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { monitor.refreshIOKitOnly() }
        }, context)?.takeRetainedValue()

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }
        if let obs = powerObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let wakeObs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObs)
        }
        if let focusObs = focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(focusObs)
        }
        if let deactivateObs = deactivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(deactivateObs)
        }
        backgroundPollTimer?.invalidate()
        activePollTimer?.invalidate()
        logRecordingTimer?.invalidate()
        autoLPMReconcileTimer?.invalidate()
    }
}
