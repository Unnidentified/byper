//
// AppDelegate.swift
// Native macOS Battery Menu Bar Companion App
//

import AppKit
import SwiftUI
import Combine
import Carbon
import Security

@main
struct ByperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popoverPanel: PopoverPanelController!
    var monitor = BatteryMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var lastRenderKey: String = ""
    private var cachedImage: NSImage? = nil
    private var appearanceObservation: NSKeyValueObservation?
    private var lastMenuBarAppearance: NSAppearance.Name?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    // App Nap opt-out: an LSUIElement app with no visible windows gets its timers
    // throttled when the display sleeps, which silently killed the threshold
    // automation (4s poll missed the SoC window). This assertion keeps OUR process
    // schedulable, and it never touches display sleep or powerd.
    private var napActivity: NSObjectProtocol?

    private func registerFonts() {
        guard let fontURL = Bundle.main.url(forResource: "fonts", withExtension: nil) else { return }
        guard let enumerator = FileManager.default.enumerator(at: fontURL, includingPropertiesForKeys: nil) else { return }
        
        var fontURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "ttf" {
                fontURLs.append(fileURL)
            }
        }
        if !fontURLs.isEmpty {
            CTFontManagerRegisterFontsForURLs(fontURLs as CFArray, .process, nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerFonts()
        NSApp.setActivationPolicy(.accessory)
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "byper: threshold automation timer must fire while display is off"
        )
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let view = BatteryDropdownView(
            monitor: monitor,
            onSelectPowerMode: { [weak self] mode in
                guard let self = self else { return }
                self.monitor.setPowerMode(mode)
                if let button = self.statusItem.button {
                    self.updateButton(button)
                }
            },
            onToggleLowPower: { [weak self] enabled in
                guard let self = self else { return }
                self.monitor.isManualLowPowerMode = enabled
                self.monitor.isLowPowerMode = enabled
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = CLIEngineBridge.setLowPowerModeSync(enabled: enabled)
                    DispatchQueue.main.async {
                        // Manual switch outranks auto: turning it OFF hands
                        // control straight back to the per-app automation
                        // (re-engages if an auto app is frontmost, no-op otherwise).
                        if !enabled { self.monitor.reconcileAutoLPM() }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.monitor.refresh()
                    }
                }
            },
            onOpenSettings: { [weak self] in
                guard let self = self else { return }
                self.popoverPanel.close()
                DispatchQueue.global(qos: .userInitiated).async {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first {
                            app.activate()
                        }
                    }
                }
            },
            onExportLog: { [weak self] in
                guard let self = self else { return }
                self.monitor.exportSessionLog { path, success in
                    if let path = path, success {
                        self.monitor.exportMessage = "Saved to Desktop [✓]"
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    } else {
                        self.monitor.exportMessage = "Export failed"
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.monitor.exportMessage = ""
                    }
                }
            }
        )
        
        // The shell is a borderless panel, not an NSPopover: the popover draws its
        // own background and arrow, which would sit behind the glass and add a
        // second notch. The panel is transparent and the SwiftUI shell owns the
        // whole outline, notch included.
        popoverPanel = PopoverPanelController { view }
        popoverPanel.onShow = { [weak self] in
            // The system draws its own highlight pill while the button is pressed;
            // forcing isHighlighted here fought that rendering and made the pill
            // background flicker on every click. Leave it to AppKit.
            self?.monitor.startActivePolling()
        }
        popoverPanel.onClose = { [weak self] in
            guard let self = self else { return }
            self.monitor.stopActivePolling()
            // Drop any in-progress preset rename so reopening starts clean
            self.monitor.renamingPreset = nil
            self.monitor.renameText = ""
        }

        if let button = statusItem.button {
            updateButton(button)
            button.action = #selector(togglePopover(_:))
            button.target = self

            // The button's effective appearance is the menu bar's own: it
            // flips between VibrantLight and VibrantDark the moment the
            // wallpaper changes, which is the signal the app's appearance
            // never carries. The same property also passes through the plain
            // Aqua/DarkAqua values while the bar redraws, so only the vibrant
            // pair counts, and only when it actually changes.
            lastMenuBarAppearance = button.effectiveAppearance.name
            if let name = lastMenuBarAppearance {
                popoverPanel.menuBarIsDark = (name == .vibrantDark || name == .darkAqua)
            }
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
                guard let self = self, let name = change.newValue?.name else { return }
                guard name == .vibrantDark || name == .vibrantLight else { return }
                guard name != self.lastMenuBarAppearance else { return }
                self.lastMenuBarAppearance = name
                self.popoverPanel.menuBarIsDark = (name == .vibrantDark)
                self.refreshIcon()
            }
        }

        // Subscribe to monitor changes (only updates button image when percentage/state changes)
        monitor.objectWillChange
            .receive(on: DispatchQueue.main)
            // Throttle: every state change still reaches the icon promptly, without
            // re-rendering at the wave timer's 60fps rate
            .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self = self, let button = self.statusItem.button else { return }
                self.updateButton(button)
            }
            .store(in: &cancellables)

        // Instant panel frame snap when dropdown menus expand/collapse (locked to the shell width).
        // showLoggerInfo (Logger "i" description) and isCaffeineMenuExpanded also change the
        // content height. Without them the panel keeps its expanded height on collapse.
        // isCaffeineAppPickerExpanded is the per-app caffeinate list: it is a second
        // expandable block inside the caffeinate row, so it needs its own entry here.
        Publishers.Merge4(
            monitor.$isBypassMenuExpanded,
            monitor.$isAppPickerExpanded,
            monitor.$isThresholdMenuExpanded,
            monitor.$isCaffeineMenuExpanded
        )
        .merge(with: monitor.$showLoggerInfo)
        .merge(with: monitor.$isSlowChargeMenuExpanded)
        .merge(with: monitor.$isBypassOptionsExpanded)
        .merge(with: monitor.$isCaffeineAppPickerExpanded)
        .merge(with: monitor.$isAppPickerSubmenuExpanded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.popoverPanel.refit()
                // Re-fit once SwiftUI commits the layout change so the expanded picker is never clipped
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.popoverPanel.refit()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                    self?.popoverPanel.refit()
                }
            }
            .store(in: &cancellables)

        // The row summaries collapse while their set is empty, so the panel
        // height changes on the first check and on the last uncheck. Those are
        // not expandable flags, so they get their own refit trigger. The mask
        // only changes when a row's summary appears or disappears, never when a
        // second item joins a non-empty set, so the row height stays stable.
        Publishers.CombineLatest4(
            monitor.$disableBypassOnQuit,
            monitor.$autoLPMPerApp,
            monitor.$autoHoldOnPlug,
            monitor.$autoHoldAtLogin
        )
        .combineLatest(monitor.$autoHoldOnDisplay)
        .map { first, display -> Int in
            var mask = 0
            if first.0 { mask |= 1 }
            if first.1 { mask |= 2 }
            if first.2 || first.3 || display { mask |= 4 }
            return mask
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self = self else { return }
            self.popoverPanel.refit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.popoverPanel.refit()
            }
        }
        .store(in: &cancellables)

        installGlobalHotkey()
    }

    // AuthorizationExecuteWithPrivileges is deprecated-out of the Swift overlay but the
    // C symbol is still present; bridge it directly so the admin dialog is attributed to
    // byper (with Touch ID) instead of "a script started by bash" (the osascript route).
    @_silgen_name("AuthorizationExecuteWithPrivileges")
    private static func authExecuteWithPrivileges(
        _ authorization: AuthorizationRef,
        _ pathToTool: UnsafePointer<CChar>,
        _ options: UInt32,
        _ arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        _ communicationsPipe: OpaquePointer?
    ) -> OSStatus

    private func runPrivilegedInstall() {
        // Privileged install via our own helper binary (Resources/byper-installer),
        // executed with AuthorizationExecuteWithPrivileges: the admin dialog is
        // attributed to byper and SecurityAgent can offer Touch ID. `do shell script
        // ... with administrator privileges` routes the request through /bin/sh and
        // shows up as "a script started by bash" instead.
        // Both paths come from the running bundle, so a source install under any
        // account works: the app is the bundle we run from and the CLI is the
        // copy the Makefile stages in Contents/Resources.
        let projectApp = Bundle.main.bundlePath
        let projectCli = Bundle.main.resourceURL?.appendingPathComponent("byper").path
            ?? projectApp + "/Contents/Resources/byper"
        guard FileManager.default.fileExists(atPath: projectApp) else {
            NSLog("byper: install aborted, app bundle not found at %@", projectApp)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: projectCli) else {
            NSLog("byper: install aborted, CLI not found at %@", projectCli)
            return
        }
        guard let helper = Bundle.main.path(forResource: "byper-installer", ofType: nil),
              FileManager.default.isExecutableFile(atPath: helper) else { return }

        var rightItem = AuthorizationItem(name: kAuthorizationRightExecute, valueLength: 0, value: nil, flags: 0)
        var rights = AuthorizationRights(count: 1, items: &rightItem)
        var authRef: AuthorizationRef?
        let authFlags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        guard AuthorizationCreate(&rights, nil, authFlags, &authRef) == errAuthorizationSuccess,
              let auth = authRef else { return }
        defer { AuthorizationFree(auth, []) }

        let appArg = strdup(projectApp)
        let cliArg = strdup(projectCli)
        defer { free(appArg); free(cliArg) }
        var argv: [UnsafeMutablePointer<CChar>?] = [appArg, cliArg, nil]
        Self.authExecuteWithPrivileges(auth, helper, 0, &argv, nil)
    }

    // Global hotkey: Cmd+Option+B toggles bypass from anywhere (Carbon, no dependencies)
    private func installGlobalHotkey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event = event, let userData = userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard hkID.id == 1 else { return noErr }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                let next: BatteryMonitor.PowerMode = appDelegate.monitor.appliedPowerMode == .bypass ? .charging : .bypass
                appDelegate.monitor.setPowerMode(next)
                if let button = appDelegate.statusItem?.button {
                    appDelegate.updateButton(button)
                }
            }
            return noErr
        }, 1, &eventType, selfPtr, &hotKeyHandler)
        guard status == noErr else { return }
        var hotKeyID = EventHotKeyID(signature: OSType(0x42595052), id: 1) // 'BYPR'
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // Resume charging on quit if the user opted in, so the machine never stays bypassing
    // or resting on a Slow Charge hold with no UI running to undo it.
    func applicationWillTerminate(_ notification: Notification) {
        if monitor.disableBypassOnQuit, monitor.isPluggedIn,
           monitor.appliedPowerMode == .bypass || monitor.isHold {
            _ = CLIEngineBridge.setPowerModeSync(.charging)
        } else if monitor.slowChargeEnabled, monitor.slowChargeOffOnExit,
                  monitor.isPluggedIn, monitor.slowChargeCycleActive {
            _ = CLIEngineBridge.setPowerModeSync(.charging)
        }
    }

    /// Drops the cached render and rebuilds the icon. The drawing handler
    /// reads the menu bar appearance when it runs, so a bar change needs a
    /// fresh image to force that handler to run again.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        lastRenderKey = ""
        updateButton(button)
    }

    func updateButton(_ button: NSStatusBarButton) {
        let isPluggedIn = monitor.isPluggedIn
        // Hardware-first icon state. Bypass = engine hold OR the pending/intent
        // union (bypassActiveOrPending covers powerMode, in-flight applies and
        // slider passes), so the copper pill is up the instant the toggle flips
        // and survives any poller race. Charging = the battery is REALLY
        // charging (hardware flag), never a mode label, so a stale
        // appliedPowerMode must not paint green over an active hold.
        // Bypass only when the apply is DONE: engine-confirmed hold or the
        // engine-confirmed applied mode. Intent/transitioning states are
        // excluded on purpose, so the copper lands when the counter snaps back
        // to 0.00s, not while the toggle is still in flight.
        let isBypass = isPluggedIn && (monitor.isHold || monitor.appliedPowerMode == .bypass)
        // Bolt the moment charging is requested (applied mode) and while the
        // hardware flag confirms it. The PMU takes a few seconds to leave the
        // hold state after `off`, so hardware-only derivation idled in between.
        // Safe now that automations commit appliedPowerMode on success.
        let isCharging = isPluggedIn && !isBypass && (monitor.isCharging || monitor.appliedPowerMode == .charging)
        
        // The pill inverts with the menu bar, which follows the wallpaper
        // rather than the popover's locked dark look. That value is read
        // inside the drawing handler, so it stays out of the render key.
        let key = "\(monitor.percentage)_\(isPluggedIn)_\(isCharging)_\(isBypass)_\(monitor.isLowPowerMode)_\(monitor.isTransitioning)_\(monitor.transitionMessage)"
        
        if key == lastRenderKey, let cached = cachedImage {
            if button.image !== cached {
                button.image = cached
            }
            return
        }
        
        let state: BatteryPillIcon.State = isCharging ? .charging
            : isBypass ? .bypass
            : monitor.isLowPowerMode ? .lowPower
            : .idle
        let img = BatteryPillIcon.image(
            level: monitor.percentage,
            state: state
        )
        lastRenderKey = key
        cachedImage = img
        button.image = img
        button.imagePosition = .imageLeft
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        popoverPanel.toggle(relativeTo: button)
    }
}
