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

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var monitor = BatteryMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var lastRenderKey: String = ""
    private var cachedImage: NSImage? = nil
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    // App Nap opt-out: an LSUIElement app with no visible windows gets its timers
    // throttled when the display sleeps, which silently killed the threshold
    // automation (4s poll missed the SoC window). This assertion keeps OUR process
    // schedulable — it never touches display sleep or powerd.
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
        
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        
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
                self.popover.performClose(nil)
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
        
        let hostingController = NSHostingController(rootView: view)
        // macOS 13+: let the hosting controller drive the popover size from SwiftUI's own
        // layout — the window resizes in one smooth step, moving only the changed section
        // (no multi-timer refit jerk). Older systems keep the manual fitting-size refits.
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = .preferredContentSize
        }
        hostingController.view.layoutSubtreeIfNeeded()
        let initialFitting = hostingController.view.fittingSize
        popover.contentSize = NSSize(width: 244, height: max(initialFitting.height, 250))
        popover.contentViewController = hostingController
        // Lock the popover to the dark look: vibrancy/popover materials otherwise follow the
        // desktop appearance and wash out on light backgrounds
        let dark = NSAppearance(named: .darkAqua)
        popover.appearance = dark
        hostingController.view.appearance = dark

        if let button = statusItem.button {
            updateButton(button)
            button.action = #selector(togglePopover(_:))
            button.target = self
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

        // Instant popover frame snap when dropdown menus expand/collapse (locked to width: 244).
        // showLoggerInfo (Logger "i" description) and isCaffeineMenuExpanded also change the
        // content height — without them the popover keeps its expanded height on collapse.
        Publishers.Merge4(
            monitor.$isBypassMenuExpanded,
            monitor.$isAppPickerExpanded,
            monitor.$isThresholdMenuExpanded,
            monitor.$isCaffeineMenuExpanded
        )
        .merge(with: monitor.$showLoggerInfo)
        .merge(with: monitor.$isSlowChargeMenuExpanded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.fitPopoverContentSize()
                // Re-fit once SwiftUI commits the layout change so the expanded picker is never clipped
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.fitPopoverContentSize()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                    self?.fitPopoverContentSize()
                }
            }
            .store(in: &cancellables)

        installGlobalHotkey()
        checkForProjectUpdate()
    }

    // MARK: - Self-update from project build (admin prompt attributed to byper, Touch ID when offered)

    private func checkForProjectUpdate() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        #if VANILLA
        // Vanilla build: never self-update from the project folder. The project
        // checkout may hold a full build (other branch), and silently replacing
        // a vanilla install with it reintroduces the excluded features.
        return
        #else
        let projectExec = "/Users/gefaass/Desktop/Documents/agent stuff/macos-ch.bypass #2/byper.app/Contents/MacOS/byper"
        let installedExec = "/Applications/byper.app/Contents/MacOS/byper"
        guard FileManager.default.fileExists(atPath: projectExec) else { return }
        let projectDate = (try? FileManager.default.attributesOfItem(atPath: projectExec))?[.modificationDate] as? Date
        let installedDate = (try? FileManager.default.attributesOfItem(atPath: installedExec))?[.modificationDate] as? Date
        guard let newDate = projectDate else { return }
        if installedDate == nil || newDate > installedDate! {
            runPrivilegedInstall()
        }
        #endif
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
        let projectApp = "/Users/gefaass/Desktop/Documents/agent stuff/macos-ch.bypass #2/byper.app"
        let projectCli = "/Users/gefaass/Desktop/Documents/agent stuff/macos-ch.bypass #2/bin/byper"
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

    // Resume charging on quit if the user opted in — never leave the machine bypassing
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

    private func fitPopoverContentSize() {
        // macOS 13+: NSHostingSizingOptions.preferredContentSize drives the popover size
        // smoothly from SwiftUI; the manual multi-timer refit would only fight it
        if #available(macOS 13.0, *) { return }
        guard popover.isShown, let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        if fitting.height > 0 {
            popover.contentSize = NSSize(width: 244, height: fitting.height)
        }
    }

    func updateButton(_ button: NSStatusBarButton) {
        let isPluggedIn = monitor.isPluggedIn
        // Hardware-first icon state. Bypass = engine hold OR the pending/intent
        // union (bypassActiveOrPending covers powerMode, in-flight applies and
        // slider passes), so the plug icon is up the instant the toggle flips
        // and survives any poller race. Bolt = the battery is REALLY charging
        // (hardware flag), never a mode label — a stale appliedPowerMode must
        // not draw a bolt over an active hold.
        let isBypass = isPluggedIn && (monitor.bypassActiveOrPending || monitor.appliedPowerMode == .bypass)
        let isCharging = isPluggedIn && !isBypass && monitor.isCharging
        
        let key = "\(monitor.percentage)_\(isPluggedIn)_\(isCharging)_\(isBypass)_\(monitor.isLowPowerMode)_\(monitor.isTransitioning)_\(monitor.transitionMessage)"
        
        if key == lastRenderKey, let cached = cachedImage {
            if button.image !== cached {
                button.image = cached
            }
            return
        }
        
        let img = BatteryAssetResolver.resolveIcon(
            percentage: monitor.percentage,
            isCharging: isCharging,
            isBypass: isBypass,
            isLowPowerMode: monitor.isLowPowerMode
        )
        lastRenderKey = key
        cachedImage = img
        button.image = img
        button.imagePosition = .imageLeft
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if let view = popover.contentViewController?.view {
                view.layoutSubtreeIfNeeded()
                let fitting = view.fittingSize
                if fitting.height > 0 {
                    popover.contentSize = NSSize(width: 244, height: fitting.height)
                }
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - NSPopoverDelegate (Starts/Stops on-demand polling & animation only while open)
    func popoverWillShow(_ notification: Notification) {
        statusItem.button?.isHighlighted = true
        monitor.startActivePolling()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.isHighlighted = false
        monitor.stopActivePolling()
        // Drop any in-progress preset rename so reopening the popover starts clean
        monitor.renamingPreset = nil
        monitor.renameText = ""
    }
}
