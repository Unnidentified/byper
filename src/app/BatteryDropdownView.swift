//
// BatteryDropdownView.swift
// Native macOS Battery Menu Bar Companion App
//

import SwiftUI

struct CheckmarkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: {
            configuration.isOn.toggle()
        }) {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundColor(configuration.isOn ? .white : Color(white: 0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Back-deployment helpers: tint is macOS 13+, controlSize macOS 12+; degrade gracefully on 11
struct BackDeployedTint: ViewModifier {
    var color: Color
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.tint(color)
        } else {
            content.accentColor(color)
        }
    }
}

struct BackDeployedMiniControl: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.controlSize(.mini)
        } else {
            content
        }
    }
}

import AppKit

// Per-App Auto LPM picker, isolated from the parent's 60fps wave re-renders.
// Plain-value inputs + manual Equatable (closures excluded) let SwiftUI skip the
// whole subtree while the app list and selection are unchanged, and LazyVStack
// keeps only on-screen rows alive — scrolling stays native-smooth even with a
// hundred apps in the list.
private struct AppPickerList: View, Equatable {
    let apps: [InstalledAppInfo]
    let selectedIds: Set<String>
    let iconProvider: (InstalledAppInfo) -> NSImage
    let onToggle: (String, Bool) -> Void

    static func == (lhs: AppPickerList, rhs: AppPickerList) -> Bool {
        lhs.apps == rhs.apps && lhs.selectedIds == rhs.selectedIds
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if apps.isEmpty {
                    Text("Scanning applications...")
                        .font(.custom("FiraCode-Regular", size: 9.5))
                        .foregroundColor(Color(white: 0.5))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 2)
                }
                ForEach(apps) { app in
                    HStack(spacing: 6) {
                        Image(nsImage: iconProvider(app))
                            .resizable()
                            .frame(width: 14, height: 14)
                        Text(app.name)
                            .font(.custom("FiraCode-Regular", size: 10.5))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Toggle("", isOn: Binding(
                            get: { selectedIds.contains(app.bundleID) },
                            set: { onToggle(app.bundleID, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(CheckmarkToggleStyle())
                    }
                    .frame(height: 18)
                }
            }
            .padding(6)
        }
    }
}

struct BatteryDropdownView: View {
    @ObservedObject var monitor: BatteryMonitor
    var onSelectPowerMode: ((BatteryMonitor.PowerMode) -> Void)?
    var onToggleLowPower: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onExportLog: (() -> Void)?

    // Distinct & Varied Color Design System
    static let coolBrownOrange = Color(red: 0.86, green: 0.50, blue: 0.22) // #DC8038 - Metallic Copper / Brown-Orange
    static let emeraldGreen = Color(red: 0.19, green: 0.82, blue: 0.35)   // #30D158 - Fast Charging
    static let solarGold = Color(red: 1.0, green: 0.84, blue: 0.04)      // #FFD60A - Low Power Mode
    static let neonMintTeal = Color(red: 0.0, green: 0.95, blue: 0.72)   // #00F2B8 - "ACTIVE" Badge
    static let graphWarmSolar = Color(red: 0.96, green: 0.58, blue: 0.16) // #F59429 - Warm Solar Copper
    static let thermoAmber = Color(red: 1.0, green: 0.60, blue: 0.12)    // #FF991F - Temperature Icon

    private var effectiveHoldActive: Bool {
        return monitor.isPluggedIn && (monitor.powerMode == .bypass || monitor.isHold)
    }

    private var themeColor: Color {
        if monitor.isLowPowerMode {
            return Self.solarGold
        } else {
            return Self.emeraldGreen
        }
    }
    
    private var graphColor: Color {
        if monitor.temperature >= 40.0 {
            return Color(red: 1.0, green: 0.30, blue: 0.30)
        } else {
            return Self.graphWarmSolar
        }
    }
    
    


    private func formatLogDuration(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 1. Header & Real-Time Battery Bar
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    


                    // Horizontal Progress Capsule
                    GeometryReader { geo in
                        let p = CGFloat(max(0.0, min(1.0, Double(monitor.percentage) / 100.0)))
                        ZStack(alignment: .leading) {
                            // Empty part (Masked so it doesn't bleed under the clear gradient edges)
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                                .frame(width: geo.size.width)
                                .mask(
                                    HStack(spacing: 0) {
                                        Color.clear.frame(width: geo.size.width * p)
                                        Color.white.frame(width: geo.size.width * (1.0 - p))
                                    }
                                )
                                
                            // Filled part (Dissolves on both ends into the dark app background)
                            Capsule()
                                .fill(LinearGradient(
                                     colors: [Color.clear, themeColor, Color.clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: max(5.0, geo.size.width * p))
                                .shadow(color: themeColor.opacity(0.35), radius: 2.5, x: 0, y: 0)

                        }
                    }
                    .frame(height: 4)

                    Text("\(monitor.percentage)%")
                        .font(.custom("FiraCode-Bold", size: 10.5))
                        .foregroundColor(.white)
                        
                    Spacer(minLength: 4)
                    
                    Button(action: {
                        NSApplication.shared.terminate(nil)
                    }) {
                        Image(systemName: "power")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(white: 0.45))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                MasterPowerSwitch(monitor: monitor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                // 24-Hour 3D Glowing Thermal Dissipation Curve (Zero Background CPU)
                VStack(spacing: 0) {
                    ThermalDissipationCurveView(
                        samples: monitor.temperatureHistory,
                        color: graphColor,
                        isActive: monitor.isPopoverVisible,
                        temperature: monitor.temperature,
                          wavePhase: monitor.wavePhase
                    )
                    .frame(height: 38)
                    .overlay(
                        masterCounterLabel(),
                          alignment: .topLeading
                    )
                    .padding(.top, 9)

                    HStack(alignment: .center) {
                        if !monitor.adapterInfo.isEmpty {
                            Text(monitor.adapterInfo)
                                .font(.custom("FiraCode-Bold", size: 9))
                                .foregroundColor(Color(white: 0.55))
                                .lineLimit(1)
                        } else {
                            Text(monitor.isPluggedIn ? "AC Connected" : "Battery Power")
                                .font(.custom("FiraCode-Bold", size: 9))
                                .foregroundColor(Color(white: 0.55))
                        }

                        Spacer()

                        // Temperature number lives on the graph endpoint; label stays here
                        Text("batt-temp")
                            .font(.custom("FiraCode-Bold", size: 9))
                            .foregroundColor(Color(white: 0.55))
                    }
                    .padding(.top, 12)
                    .padding(.bottom, -2)
                }

            Divider()
                .background(Color.white.opacity(0.12))
                .padding(.bottom, 6)

            // 2. AC Power Bypass Control Section (3-Way Switch: Charging, Disable, Bypass)

                // Presets: Travel / Docked — click to activate, click again to restore; long-press a name to rename
                HStack(spacing: 4) {
                    Image(systemName: "switch.2")
                        .font(.custom("FiraCode-Regular", size: 10))
                        .foregroundColor(Color(white: 0.55))
                        .frame(width: 18, alignment: .center)

                    Text("Presets")
                        .font(.custom("FiraCode-SemiBold", size: 11))
                        .foregroundColor(.white)

                    Spacer()

                    HStack(spacing: 4) {
                        presetModeButton(.travel)
                        presetModeButton(.docked)
                    }
                    .padding(.trailing, 5)
                }
                .frame(height: 16)
                .masterRowProbe("presets")

                // Rounded enclosure: encompasses all the settings below the presets
                VStack(alignment: .leading, spacing: 4) {

                HStack(spacing: 4) {
                    let activeMode = monitor.isTransitioning ? (monitor.targetPowerMode ?? monitor.powerMode) : monitor.powerMode
                    let isBypass = (activeMode == .bypass)
                    let iconName = isBypass ? "powerplug.fill" : "bolt.fill"
                    let iconColor = isBypass ? Self.coolBrownOrange : Self.emeraldGreen
                    
                    Image(systemName: iconName)
                        .font(.custom("FiraCode-Regular", size: 10))
                        .foregroundColor(monitor.isPluggedIn && isBypass ? iconColor : Color(white: 0.38))
                        .frame(width: 18, alignment: .center)

                    Text("Bypass Charge")
                        .font(.custom("FiraCode-SemiBold", size: 11))
                        .foregroundColor(monitor.isPluggedIn && isBypass ? .white : Color(white: 0.38))
                        .lineLimit(1)

                      Spacer()

                    Button(action: {
                        monitor.isBypassOptionsExpanded.toggle()
                      }) {
                        Image(systemName: "chevron.right")
                            .font(.custom("FiraCode-Bold", size: 8.5))
                            .foregroundColor(Color(white: 0.38))
                            .rotationEffect(.degrees(monitor.isBypassOptionsExpanded ? 90 : 0))
                            .contentShape(Rectangle())
                      }
                      .buttonStyle(.plain)
                      .accessibilityLabel("Bypass Options")
                      .padding(.trailing, 2)

                      Toggle("", isOn: Binding(
                        get: { (monitor.isTransitioning ? (monitor.targetPowerMode ?? monitor.powerMode) : monitor.powerMode) == .bypass },
                        set: { val in
                            // Only one or another: Bypass cannot engage while Slow
                            // Charge is enabled (the switch is also visually locked)
                            guard !(val && monitor.slowChargeEnabled) else { return }
                            onSelectPowerMode?(val ? .bypass : .charging)
                        }
                    ))
                    .labelsHidden()
                    .scaleEffect(0.70, anchor: .trailing)
                    // clamp the hidden layout footprint (scaleEffect keeps the full
                    // switch width) so inline numbers never expand the row. Frame +
                    // trailing padding align the switch's visual right edge with the
                    // Docked pill's right edge on the presets row (visual switch =
                    // 38 x 0.70 = 26.6pt, trailing at the row's 5pt pill padding)
                    .frame(width: 26.6, alignment: .trailing)
                    .toggleStyle(SmoothSwitchToggleStyle(tint: Self.coolBrownOrange))
                    .grayscale(monitor.isPluggedIn ? 0 : 1)
                    .opacity(monitor.isPluggedIn ? 1 : 0.4)
                    .padding(.trailing, 5)
                    .disabled(!monitor.isPluggedIn || monitor.isTransitioning || monitor.slowChargeEnabled)
                    .opacity(monitor.slowChargeEnabled ? 0.4 : 1)
                    .allowsHitTesting(monitor.masterRowEnabled("bypass"))
                }
                .frame(height: 16)
                .masterRowProbe("bypass")

                if monitor.isBypassOptionsExpanded {
                    HStack {
                        Text("Off on exit")
                            .font(.custom("FiraCode-Medium", size: 10.5))
                            .foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $monitor.disableBypassOnQuit)
                            .labelsHidden()
                            .toggleStyle(CheckmarkToggleStyle())
                            .padding(.trailing, 8)
                    }
                    .padding(.leading, 22)
                    .frame(height: 16)
                    .allowsHitTesting(monitor.masterRowEnabled("bypass"))
                }




                HStack(spacing: 4) {
                    Image(systemName: "leaf.fill")
                        .font(.custom("FiraCode-Regular", size: 10))
                        .foregroundColor(monitor.masterRowEnabled("lpm") && (monitor.checkedVisibleApps > 0 || monitor.isLowPowerMode) ? Self.solarGold : Color(white: 0.38))
                        .frame(width: 18, alignment: .center)

                    Text("Powersave")
                        .foregroundColor(monitor.masterRowEnabled("lpm") && (monitor.checkedVisibleApps > 0 || monitor.isLowPowerMode) ? .white : Color(white: 0.38))
                        .font(.custom("FiraCode-SemiBold", size: 11))
                        

                    Spacer()

                    Button(action: {
                        monitor.isAppPickerExpanded.toggle()
                        if monitor.isAppPickerExpanded {
                            monitor.loadInstalledAppsIfNeeded()
                        }
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.custom("FiraCode-Bold", size: 8.5))
                            .foregroundColor(Color(white: 0.45))
                            .rotationEffect(.degrees(monitor.isAppPickerExpanded ? 90 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Auto LPM Apps")
                    .padding(.trailing, 2)

                    Toggle("", isOn: Binding(
                        get: { monitor.isLowPowerMode },
                        set: { val in
                            monitor.isLowPowerMode = val
                            onToggleLowPower?(val)
                        }
                    ))
                    .labelsHidden()
                    .scaleEffect(0.70, anchor: .trailing)
                    // same Docked-right alignment as the bypass row (see comment there)
                    .frame(width: 26.6, alignment: .trailing)
                    .toggleStyle(SmoothSwitchToggleStyle(tint: Self.solarGold))
                    .padding(.trailing, 5)
                }
                .frame(height: 16)
                .allowsHitTesting(monitor.masterRowEnabled("lpm"))
                .masterRowProbe("lpm")

                if monitor.isAppPickerExpanded {
                    AppPickerList(
                        apps: monitor.installedApps,
                        selectedIds: monitor.autoLPMBundleIds,
                        iconProvider: { monitor.icon(for: $0) },
                        onToggle: { id, enabled in
                            if enabled {
                                monitor.autoLPMBundleIds.insert(id)
                            } else {
                                monitor.autoLPMBundleIds.remove(id)
                            }
                        }
                    )
                    .equatable()
                    .frame(height: 160)
                    .allowsHitTesting(monitor.masterRowEnabled("lpm"))
                    // width follows the enclosure proposal; fixedSize(horizontal:) would
                    // inflate the picker (and every row in the enclosure) to the widest
                    // untruncated app name
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                }

                // Threshold Menu: Auto Bypass at Battery Threshold
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.needle")
                        .font(.custom("FiraCode-Regular", size: 10))
                        .foregroundColor(monitor.autoBypassThresholdEnabled ? Self.coolBrownOrange : Color(white: 0.38))
                        .frame(width: 18, alignment: .center)

                    Text("Threshold")
                        .font(.custom("FiraCode-SemiBold", size: 11))
                        .foregroundColor(monitor.autoBypassThresholdEnabled ? .white : Color(white: 0.38))
                        .lineLimit(1)
                          .fixedSize()

                      Text("- \(monitor.autoBypassThreshold)%")
                          .font(.custom("FiraCode-Bold", size: 9.5))
                          .foregroundColor(monitor.autoBypassThresholdEnabled ? Self.coolBrownOrange : Color(white: 0.38))
                          .lineLimit(1)
                          .fixedSize()

                    Spacer()

                    Button(action: {
                        monitor.isThresholdMenuExpanded.toggle()
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.custom("FiraCode-Bold", size: 8.5))
                            .foregroundColor(Color(white: 0.38))
                            .rotationEffect(.degrees(monitor.isThresholdMenuExpanded ? 90 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Threshold Slider")
                    .padding(.trailing, 2)

                    Toggle("", isOn: $monitor.autoBypassThresholdEnabled)
                        .labelsHidden()
                        .scaleEffect(0.70, anchor: .trailing)
                        // same Docked-right alignment as the bypass row (see comment there)
                        .frame(width: 26.6, alignment: .trailing)
                        .toggleStyle(SmoothSwitchToggleStyle(tint: Self.coolBrownOrange))
                        .padding(.trailing, 5)
                }
                .frame(height: 16)
                .allowsHitTesting(monitor.masterRowEnabled("threshold"))
                .masterRowProbe("threshold")

                if monitor.isThresholdMenuExpanded {
                    Slider(value: Binding(
                        get: { Double(monitor.autoBypassThreshold) },
                        set: { monitor.autoBypassThreshold = Int($0.rounded()) }
                    ), in: 10...90)
                        .modifier(BackDeployedTint(color: Self.coolBrownOrange))
                        .modifier(BackDeployedMiniControl())
                        .scaleEffect(y: 0.55)
                        .padding(.leading, 22)
                        .padding(.trailing, 33)
                        .frame(height: 12)
                        .allowsHitTesting(monitor.masterRowEnabled("threshold"))
                }

                // Caffeinate Menu: Keep screen on (auto with bypass, or always)
                HStack(spacing: 4) {
                    Image(systemName: "display")
                        .font(.custom("FiraCode-Regular", size: 10))
                        .foregroundColor(monitor.caffeineActive ? Self.solarGold : Color(white: 0.38))
                        .frame(width: 18, alignment: .center)

                    Text("Caffeinate")
                        .font(.custom("FiraCode-SemiBold", size: 11))
                        .foregroundColor(monitor.caffeineActive ? .white : Color(white: 0.38))

                    Spacer()

                    Button(action: {
                        monitor.isCaffeineMenuExpanded.toggle()
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.custom("FiraCode-Bold", size: 8.5))
                            .foregroundColor(Color(white: 0.38))
                            .rotationEffect(.degrees(monitor.isCaffeineMenuExpanded ? 90 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Caffeinate Options")
                    .padding(.trailing, 2)

                    Toggle("", isOn: Binding(
                        // armed-auto only lights the master switch on AC; while unplugged
                        // caffeinate can never engage, so the switch must stay off
                        get: { monitor.caffeineAlwaysOn || (monitor.autoCaffeineOnBypass && monitor.isPluggedIn) },
                        set: { val in
                            monitor.caffeineAlwaysOn = val
                            monitor.autoCaffeineOnBypass = val
                        }
                    ))
                        .labelsHidden()
                        .scaleEffect(0.70, anchor: .trailing)
                        // same Docked-right alignment as the bypass row (see comment there)
                        .frame(width: 26.6, alignment: .trailing)
                        .toggleStyle(SmoothSwitchToggleStyle(tint: Self.solarGold))
                        .padding(.trailing, 5)
                }
                .frame(height: 16)
                .allowsHitTesting(monitor.masterRowEnabled("caffeine"))
                .masterRowProbe("caffeine")

                if monitor.isCaffeineMenuExpanded {
                    HStack {
                        Text("Auto Enable on Bypass")
                            .font(.custom("FiraCode-Medium", size: 10.5))
                            .foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $monitor.autoCaffeineOnBypass)
                            .labelsHidden()
                            .toggleStyle(CheckmarkToggleStyle())
                            .padding(.trailing, 8)
                    }
                    .padding(.leading, 22)
                    .frame(height: 16)
                    .allowsHitTesting(monitor.masterRowEnabled("caffeine"))
                }

                // Slow Charge: duty-cycled burst charging (hold/burst alternation)
                HStack(spacing: 4) {
                    Image(systemName: "battery.25percent")
                        .font(.custom("FiraCode-Regular", size: 10))
                        .foregroundColor(monitor.slowChargeEnabled ? Self.coolBrownOrange : Color(white: 0.38))
                        .frame(width: 18, alignment: .center)

                    Text("Slow Charge")
                        .font(.custom("FiraCode-SemiBold", size: 11))
                        .foregroundColor(monitor.slowChargeEnabled ? .white : Color(white: 0.38))
                        .lineLimit(1)

                    Spacer()

                    Button(action: {
                        monitor.isSlowChargeMenuExpanded.toggle()
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.custom("FiraCode-Bold", size: 8.5))
                            .foregroundColor(Color(white: 0.38))
                            .rotationEffect(.degrees(monitor.isSlowChargeMenuExpanded ? 90 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Slow Charge Options")
                    .padding(.trailing, 2)

                    Toggle("", isOn: $monitor.slowChargeEnabled)
                        .labelsHidden()
                        .scaleEffect(0.70, anchor: .trailing)
                        // same Docked-right alignment as the bypass row (see comment there)
                        .frame(width: 26.6, alignment: .trailing)
                        .toggleStyle(SmoothSwitchToggleStyle(tint: Self.coolBrownOrange))
                        .padding(.trailing, 5)
                        // Only one or another: the switch locks while Bypass is engaged
                        .disabled(!monitor.isPluggedIn || monitor.powerMode == .bypass || monitor.isHold)
                        .grayscale(!monitor.isPluggedIn || monitor.powerMode == .bypass || monitor.isHold ? 1 : 0)
                        .opacity(!monitor.isPluggedIn ? 0.4 : 1)
                        .allowsHitTesting(monitor.masterRowEnabled("slowcharge"))
                }
                .frame(height: 16)
                .masterRowProbe("slowcharge")

                if monitor.isSlowChargeMenuExpanded {
                    HStack {
                        Text("Always On")
                            .font(.custom("FiraCode-Medium", size: 10.5))
                            .foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $monitor.slowChargeAlwaysOn)
                            .labelsHidden()
                            .toggleStyle(CheckmarkToggleStyle())
                            .disabled(monitor.slowChargeOffOnExit)
                            .opacity(monitor.slowChargeOffOnExit ? 0.4 : 1)
                            .padding(.trailing, 8)
                    }
                    .padding(.leading, 22)
                    .frame(height: 16)
                    .allowsHitTesting(monitor.masterRowEnabled("slowcharge"))

                    HStack {
                        Text("Off on exit")
                            .font(.custom("FiraCode-Medium", size: 10.5))
                            .foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $monitor.slowChargeOffOnExit)
                            .labelsHidden()
                            .toggleStyle(CheckmarkToggleStyle())
                            .disabled(monitor.slowChargeAlwaysOn)
                            .opacity(monitor.slowChargeAlwaysOn ? 0.4 : 1)
                            .padding(.trailing, 8)
                    }
                    .padding(.leading, 22)
                    .frame(height: 16)
                    .allowsHitTesting(monitor.masterRowEnabled("slowcharge"))
                }

                HStack {
                    Button(action: {
                        monitor.isBypassMenuExpanded.toggle()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape.fill")
                                .font(.custom("FiraCode-Regular", size: 10))
                                .foregroundColor(Color(white: 0.55 - 0.17 * monitor.rowFadeProgress("settings")))
                                .frame(width: 18, alignment: .center)
                                
                            Text("Settings")
                                .font(.custom("FiraCode-SemiBold", size: 11))
                                .foregroundColor(Color(white: 1.0 - 0.62 * monitor.rowFadeProgress("settings")))

                            Image(systemName: "chevron.right")
                                .font(.custom("FiraCode-Bold", size: 8.5))
                                .foregroundColor(Color(white: 0.45 - 0.07 * monitor.rowFadeProgress("settings")))
                                .rotationEffect(.degrees(monitor.isBypassMenuExpanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .frame(height: 16)
                .allowsHitTesting(monitor.masterRowEnabled("settings"))
                .masterRowProbe("settings")
                    // Automation Sub-Menu (Instant Snap, Zero Animation)
                    if monitor.isBypassMenuExpanded {
                        VStack(alignment: .leading, spacing: 7) {
                            // Automation 1: Plug-in behavior
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Auto Bypass on Connect")
                                        .font(.custom("FiraCode-Medium", size: 10.5))
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                Toggle("", isOn: $monitor.autoHoldOnPlug)
                                    .labelsHidden()
                                    .toggleStyle(CheckmarkToggleStyle())
                            }

                            Divider().background(Color.white.opacity(0.08))

                            // Automation 2: Launch / Bypass at Login
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Auto Bypass at Login")
                                        .font(.custom("FiraCode-Medium", size: 10.5))
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                Toggle("", isOn: $monitor.autoHoldAtLogin)
                                    .labelsHidden()
                                    .toggleStyle(CheckmarkToggleStyle())
                            }

                            Divider().background(Color.white.opacity(0.08))

                            // Automation 3: External Display
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Auto Bypass on Display")
                                        .font(.custom("FiraCode-Medium", size: 10.5))
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                Toggle("", isOn: $monitor.autoHoldOnDisplay)
                                    .labelsHidden()
                                    .toggleStyle(CheckmarkToggleStyle())
                            }

                            Divider().background(Color.white.opacity(0.08))

                            // Automation 4: Session Telemetry Logger (Play/Stop + Live Seconds + Export)
                            if monitor.showLoggerInfo {
                                Text("Records your battery's power, temperature, and charging history into a spreadsheet on your Desktop.")
                                    .font(.custom("FiraCode-Regular", size: 9.5))
                                    .foregroundColor(Color(white: 0.65))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, 6)
                                    .padding(.horizontal, 4)
                            }
                            HStack(spacing: 4) {
                                loggerRecordButton()

                                // Live Seconds Counter & Status
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        if monitor.isRecordingLog {
                                            Circle()
                                                .fill(Color.red)
                                                .frame(width: 4.5, height: 4.5)
                                            Text("REC \(formatLogDuration(monitor.recordingDurationSec))")
                                                .font(.custom("FiraCode-Bold", size: 10.5))
                                                .foregroundColor(.white)
                                        } else if monitor.recordingDurationSec > 0 {
                                            Text("PAUSED \(formatLogDuration(monitor.recordingDurationSec))")
                                                .font(.custom("FiraCode-SemiBold", size: 10.5))
                                                .foregroundColor(Color(white: 0.7))
                                        } else {
                                            HStack(spacing: 4) {
                                                Text("Logger")
                                                    .font(.custom("FiraCode-Medium", size: 10.5))
                                                    .foregroundColor(.white)
                                                
                                                Button(action: {
                                                    monitor.showLoggerInfo.toggle()
                                                }) {
                                                    Image(systemName: "info.circle")
                                                        .font(.system(size: 9))
                                                        .foregroundColor(Color(white: 0.5))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }

                                        // Simple Reset Button (Next to the timer)
                                        if monitor.recordingDurationSec > 0 || monitor.isRecordingLog {
                                            Button(action: {
                                                monitor.resetLogRecording()
                                            }) {
                                                Image(systemName: "arrow.counterclockwise")
                                                    .font(.custom("FiraCode-Bold", size: 8))
                                                    .foregroundColor(Color(white: 0.55))
                                                    .padding(2.5)
                                                    .background(Circle().fill(Color.white.opacity(0.08)))
                                            }
                                            .buttonStyle(.plain)
                                            .help("Reset session log counter")
                                        }
                                    }

                                    Text(monitor.exportMessage.isEmpty ? (monitor.isRecordingLog ? "\(monitor.recordedSampleCount) samples recorded" : "Record live session to Desktop") : monitor.exportMessage)
                                        .font(.custom("FiraCode-Regular", size: 9))
                                        .foregroundColor(monitor.exportMessage.isEmpty ? Color(white: 0.5) : Self.neonMintTeal)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                // Export Button (Saves snapshot & keeps recording going if active)
                                Button(action: {
                                    onExportLog?()
                                }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.down.doc.fill")
                                            .font(.custom("FiraCode-Regular", size: 8.5))
                                        Text("Export")
                                            .font(.custom("FiraCode-SemiBold", size: 10))
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3.5)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
                                    .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                    }
                  }
                }
                .padding(.horizontal, 8)
                // bottom inset matches the divider→Presets gap (6 padding + 4 VStack spacing)
                .padding(.bottom, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.30, green: 0.10, blue: 0.00).opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .padding(.top, 6)
                }
                  // Master fade covers the whole menu column (graph labels → presets → enclosure)
                // so the grey line reaches every element in top-down order, presets included.
                .background(GeometryReader { g in
                      Color.clear.preference(key: MasterRowYKey.self, value: ["::height": g.size.height])
                })
                .coordinateSpace(name: "masterZone")
                  .modifier(MasterFadeModifier(level: monitor.masterLevel))
                .onPreferenceChange(MasterRowYKey.self) { monitor.updateMasterRowGeometry($0) }
            }

        .onTapGesture {
            // Clicking any non-interactive area cancels an open rename editor
            monitor.renamingPreset = nil
        }
        .padding(11)
        .frame(width: 280)
        .fixedSize(horizontal: true, vertical: false)
          .background(
            Color(red: 0.47, green: 0.16, blue: 0.00) // #782800 — low-level wash over the whole popover
                .opacity(0.10)
                .ignoresSafeArea()
        )
    }

    // Auto-focus the inline rename field once SwiftUI commits it (no @FocusState needed)
    // Graph top-left counter: counts up while a bypass switch is in flight, then
    // decays from the measured duration back to 0.00s (0.00s when idle).
    private func masterCounterLabel() -> some View {
        return Text(String(format: "%.2fs", monitor.counterValue))
            .font(.custom("FiraCode-Medium", size: 9))
            .foregroundColor(Color(white: monitor.counterCounting ? 0.7 : 0.45))
            .padding(.leading, 2)
            .padding(.top, 0)
    }

    private func focusRenameField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApplication.shared.keyWindow else { return }
            var stack: [NSView] = [window.contentView].compactMap { $0 }
            while let view = stack.popLast() {
                if let field = view as? NSTextField {
                    window.makeFirstResponder(field)
                    field.selectText(nil)
                    return
                }
                stack.append(contentsOf: view.subviews)
            }
        }
    }

    private func loggerRecordButton() -> some View {
        let rec = monitor.isRecordingLog
        return Button(action: {
            if monitor.isRecordingLog {
                monitor.stopLogRecording()
            } else {
                monitor.startLogRecording()
            }
        }) {
            ZStack {
                Circle()
                    .fill(rec ? Color.red.opacity(0.22) : Color.white.opacity(0.12))
                    .frame(width: 21, height: 21)
                    .overlay(
                        Circle()
                            .stroke(rec ? Color.red.opacity(0.6) : Color.white.opacity(0.2), lineWidth: 0.8)
                    )
                Image(systemName: rec ? "stop.fill" : "play.fill")
                    .font(.custom("FiraCode-Bold", size: 8.5))
                    .foregroundColor(rec ? Color(red: 1.0, green: 0.35, blue: 0.35) : .white)
                    .offset(x: rec ? 0 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func presetModeButton(_ preset: BatteryMonitor.Preset) -> some View {
        let isActive = monitor.activePreset == preset
        return Group {
            if monitor.renamingPreset == preset {
                TextField("Name", text: $monitor.renameText, onCommit: {
                    monitor.setPresetName(preset, monitor.renameText)
                    monitor.renamingPreset = nil
                })
                .textFieldStyle(PlainTextFieldStyle())
                .font(.custom("FiraCode-SemiBold", size: 9.5))
                .foregroundColor(.white)
                .frame(width: 60)
            } else {
                Text(monitor.presetDisplayName(preset))
                    .font(.custom("FiraCode-SemiBold", size: 9.5))
                    .foregroundColor(isActive ? .black : .white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? Self.solarGold : Color.white.opacity(0.12)))
                    .contentShape(Rectangle())
                    .onTapGesture { monitor.togglePreset(preset) }
                    .onLongPressGesture(minimumDuration: 0.5) {
                        monitor.renameText = monitor.presetDisplayName(preset)
                        monitor.renamingPreset = preset
                        focusRenameField()
                    }
            }
        }
    }
}

// MARK: - 3-Way Segmented Power Slider Switch (Left: Bolt, Middle: Disable, Right: Plug)

// MARK: - 24-Hour 3D Glowing Thermal Dissipation Curve (Zero-Overhead Timeline)
// MARK: - Master Power Switch (fat vertical pill rail on the left)
struct MasterPowerSwitch: View {
    @ObservedObject var monitor: BatteryMonitor

    var body: some View {
        GeometryReader { geo in
        let knob: CGFloat = 20
        let travel = max(0, geo.size.height - knob - 8)
        let level = monitor.masterLevel
        ZStack(alignment: .top) {
            Capsule()
                .fill(Color(red: 0.16 + 0.31 * level,   // fades brown progressively;
                                green: 0.07 + 0.13 * level, // at the bottom it bottoms out at
                                blue: 0.03 + 0.05 * level)) // dark brown, never grey
            Circle()
                .fill(level > 0.001 ? Color(red: 0.78, green: 0.58, blue: 0.48) : Color(white: 0.60))
                .frame(width: knob, height: knob)
                // Subtle inner depth only: a drop shadow here spilled past the rail's
                // rounded cap and read as a warm halo around the slider tip.
                .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 1))
                .offset(y: 4 + (1 - level) * travel)
        }
        .clipShape(Capsule())
        .frame(width: geo.size.width, height: geo.size.height)
        .animation(.spring(response: 0.30, dampingFraction: 0.7), value: monitor.masterLevel)
        .contentShape(Rectangle())
        .gesture(
            // Drag anywhere on the rail to set the level; a quick tap snaps to the nearest end
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    monitor.isDraggingMaster = true
                    guard !monitor.isTransitioning else { return }
                    let travel = max(1, geo.size.height - 28)
                    let frac = 1 - min(max((g.location.y - 14) / travel, 0), 1)
                    monitor.setMasterLevel(frac > 0.9 ? 1 : frac)
                  }
                  .onEnded { g in
                      guard !monitor.isTransitioning else { monitor.finishMasterDrag(); return }
                      let travel = max(1, geo.size.height - 28)
                    let frac = 1 - min(max((g.location.y - 14) / travel, 0), 1)
                    monitor.setMasterLevel(frac >= 0.9 ? 1 : (frac <= 0.1 ? 0 : frac))
                      monitor.finishMasterDrag()
                  }
        )
        }
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Master Switch")
    }
}
// Live geometry probe: rows report their mid-point inside the master enclosure so the
// feature cut-off lands exactly where the grey fade line sits, whatever is expanded.
struct MasterRowYKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func masterRowProbe(_ key: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: MasterRowYKey.self,
                                   value: [key: g.frame(in: .named("masterZone")).midY])
        })
    }
}

// SwiftUI-native switch: the macOS NSSwitch thumb snaps between positions with no
// interpolation, so the enclosure rows use this drawn style instead — same look, spring glide.
struct SmoothSwitchToggleStyle: ToggleStyle {
    var tint: Color
    // onTapGesture does NOT honor the .disabled() environment — without this
    // guard, .disabled() on a Toggle using this style is purely cosmetic.
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            Capsule()
                .fill(configuration.isOn ? tint : Color.white.opacity(0.07))
                .frame(width: 38, height: 22)
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            Circle()
                .fill(configuration.isOn ? Color.white : Color.white.opacity(0.35))
                .frame(width: 18, height: 18)
                .shadow(color: Color.black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: configuration.isOn)
        .onTapGesture {
            guard isEnabled else { return }
            configuration.isOn.toggle()
        }
    }
}

// MARK: - Master Slider Chronological Fade (rows grey out as the knob passes them, top-to-bottom)
struct MasterFadeModifier: ViewModifier {
    let level: Double

    func body(content: Content) -> some View {
        // Two stacked copies of the content, split at the knob position:
        // above the knob → desaturated at a visible 0.45 floor, below → full color.
        // Color loss is strictly positional (icons keep their tint until the knob
        // reaches them), and the tight 0.02 band stops the boundary from bleeding
        // dimness into rows below it. At full-off the crossfade completes, so the
        // bottom edge (Settings row + enclosure padding) never stays stuck mid-blend.
        let p = 1 - level // knob position from top, 0...1
        let end = p >= 0.98
        let a = min(max(p - 0.02, 0), 1)
        let b = min(max(p + 0.02, 0.001), 1)
        let topStops: [Gradient.Stop]
        let bottomStops: [Gradient.Stop]
        if end {
            topStops = [
                .init(color: .white.opacity(0.45), location: 0),
                .init(color: .white.opacity(0.45), location: 1),
            ]
            bottomStops = [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 1),
            ]
        } else {
            topStops = [
                .init(color: .white.opacity(0.45), location: 0),
                .init(color: .white.opacity(0.45), location: a),
                .init(color: .clear, location: b),
                .init(color: .clear, location: 1),
            ]
            bottomStops = [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: a),
                .init(color: .white, location: b),
                .init(color: .white, location: 1),
            ]
        }
        let topMask = LinearGradient(stops: topStops, startPoint: .top, endPoint: .bottom)
        let bottomMask = LinearGradient(stops: bottomStops, startPoint: .top, endPoint: .bottom)
        return ZStack {
            content
                .grayscale(1)
                .saturation(0)
                .mask(topMask)
            content
                .mask(bottomMask)
        }
    }
}

// MARK: - 24-Hour 3D Glowing Thermal Dissipation Curve (Guaranteed Silky Smooth Monotone Spline)
struct ThermalDissipationCurveView: View {
    let samples: [Double]
    let color: Color
    let isActive: Bool
    var temperature: Double = 32.0
    var wavePhase: Double = 0.0

    var body: some View {
        // wavePhase is driven by BatteryMonitor at ~60fps while the popover is open, so
        // re-renders follow the monitor's published updates on every supported OS version
        // (TimelineView(.animation) needs macOS 14+ and is intentionally not used here)
        renderContent()
    }

    @ViewBuilder
    private func renderContent() -> some View {
        let wavePhase = self.wavePhase
        
        GeometryReader { geo in
            let h = geo.size.height
            let points = Self.calculatePoints(samples: samples, width: geo.size.width, height: h, isActive: isActive, wavePhase: wavePhase)
            let curvePath = Self.buildSmoothSpline(points: points)
            
            let fillPath = Path { path in
                guard let first = points.first else { return }
                path.move(to: CGPoint(x: first.x, y: h))
                path.addLine(to: first)
                
                // Trace curve
                Self.appendSmoothSpline(to: &path, points: points)
                
                if let last = points.last {
                    path.addLine(to: CGPoint(x: last.x, y: h))
                }
                path.closeSubpath()
            }
            
            ZStack {
                // Layer 1: Ambient 3D depth fill with multi-stop vertical gradient
                fillPath
                    .fill(LinearGradient(
                        stops: [
                            .init(color: color.opacity(0.28), location: 0.0),
                            .init(color: color.opacity(0.07), location: 0.55),
                            .init(color: color.opacity(0.0), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                
                // Layer 2: Wide Diffuse Glow
                curvePath
                    .stroke(color.opacity(0.38), style: StrokeStyle(lineWidth: 5.2, lineCap: .round, lineJoin: .round))
                    .blur(radius: 3.2)
                
                // Layer 3: Concentrated Neon Halo
                curvePath
                    .stroke(color.opacity(0.68), style: StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round))
                    .blur(radius: 1.1)
                
                // Layer 4: Vivid Core Neon Tube
                curvePath
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                
                // Layer 5: 3D Specular Highlight Line
                curvePath
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 0.6, lineCap: .round, lineJoin: .round))
                    .blendMode(.screen)
                
                // Layer 6: Live 3D Glowing Head Dot on the right (with a barely-there idle bob)
                if let lastPoint = points.last {
                    let dotY = lastPoint.y + CGFloat(sin(wavePhase * 1.1) * 0.8)
                      Circle()
                        .fill(color.opacity(0.50))
                        .frame(width: 6.5, height: 6.5)
                        .blur(radius: 1.5)
                          .position(x: lastPoint.x, y: dotY)
                          .animation(.easeInOut(duration: 0.3), value: dotY)
                      
                        Circle()
                        .fill(Color.white)
                        .frame(width: 3.0, height: 3.0)
                          .shadow(color: color, radius: 2)
                            .position(x: lastPoint.x, y: dotY)
                        .animation(.easeInOut(duration: 0.3), value: dotY)
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.20), location: 0.10),
                        .init(color: .black.opacity(0.70), location: 0.25),
                        .init(color: .black, location: 0.42),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            
            // Temperature readout rides the head dot's exact height (outside the mask, unfaded),
            // easing into each frame so it glides after the dot instead of stepping
              if let lastPoint = points.last {
                  let dotY = lastPoint.y + CGFloat(sin(wavePhase * 1.1) * 0.8)
                  // number bobs at just 40% of the dot's travel — steadier than the dot
                  let numY = lastPoint.y + CGFloat(sin(wavePhase * 1.1) * 0.3)
                  Text(String(format: "%.1f", temperature))
                    .font(.custom("FiraCode-Bold", size: 9))
                    .foregroundColor(Color(white: 0.55))
                    .frame(width: 26, alignment: .leading)
                    .position(x: min(lastPoint.x + 22, geo.size.width - 13), y: numY)
                    .animation(.easeInOut(duration: 0.3), value: numY)
            }
        }
    }
    
    static func calculatePoints(samples: [Double], width: CGFloat, height: CGFloat, isActive: Bool, wavePhase: Double) -> [CGPoint] {
        let insetLeft: CGFloat = 1.0
        let insetRight: CGFloat = 48.0
        let usableWidth = max(width - insetLeft - insetRight, 10.0)
        
        let rawData = samples.isEmpty ? [30.0, 30.0] : (samples.count == 1 ? [samples[0], samples[0]] : samples)
        let currentTemp = rawData.last ?? 32.0
        let maxVal = max(rawData.max() ?? (currentTemp + 2.0), 36.0)
        let minVal = min(rawData.min() ?? (currentTemp - 2.0), 26.0)
        let range = max(maxVal - minVal, 6.0)
        
        let numPoints = 32
        var interpolatedNorm: [CGFloat] = []
        
        for i in 0..<numPoints {
            let t = CGFloat(i) / CGFloat(numPoints - 1)
            let rawIdx = t * CGFloat(rawData.count - 1)
            let idx0 = Int(floor(rawIdx))
            let idx1 = min(idx0 + 1, rawData.count - 1)
            let frac = rawIdx - CGFloat(idx0)
            
            let cosFrac = (1.0 - cos(frac * .pi)) / 2.0
            let val0 = CGFloat((rawData[idx0] - minVal) / range)
            let val1 = CGFloat((rawData[idx1] - minVal) / range)
            let smoothVal = val0 * (1.0 - cosFrac) + val1 * cosFrac
            interpolatedNorm.append(smoothVal)
        }
        
        var smoothedNorm: [CGFloat] = []
        let weights: [CGFloat] = [0.06, 0.24, 0.40, 0.24, 0.06]
        for i in 0..<numPoints {
            var sum: CGFloat = 0
            var weightSum: CGFloat = 0
            for (k, wOffset) in (-2...2).enumerated() {
                let sampleIdx = min(max(i + wOffset, 0), numPoints - 1)
                sum += interpolatedNorm[sampleIdx] * weights[k]
                weightSum += weights[k]
            }
            smoothedNorm.append(sum / weightSum)
        }
        
        return (0..<numPoints).map { i in
            let progress = CGFloat(i) / CGFloat(numPoints - 1)
            let x = insetLeft + (progress * usableWidth)
            let normalizedY = smoothedNorm[i]
            
            let waveEnvelope = sin(progress * .pi)
            let wave = isActive ? (sin(Double(progress) * .pi * 3.5 - wavePhase) * 2.8 * Double(waveEnvelope)) : 0.0
            let y = height - (normalizedY * (height - 12)) - 6.0 + CGFloat(wave)
            return CGPoint(x: x, y: y)
        }
    }
    
    static func buildSmoothSpline(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        appendSmoothSpline(to: &path, points: points)
        return path
    }
    
    static func appendSmoothSpline(to path: inout Path, points: [CGPoint]) {
        guard points.count > 1 else { return }
        if points.count == 2 {
            path.addLine(to: points[1])
            return
        }
        
        let n = points.count
        var tangents: [CGPoint] = Array(repeating: .zero, count: n)
        
        // Calculate smooth continuous tangents at each vertex
        tangents[0] = CGPoint(x: (points[1].x - points[0].x) * 0.5, y: (points[1].y - points[0].y) * 0.5)
        tangents[n - 1] = CGPoint(x: (points[n - 1].x - points[n - 2].x) * 0.5, y: (points[n - 1].y - points[n - 2].y) * 0.5)
        
        for i in 1..<(n - 1) {
            let dx = (points[i + 1].x - points[i - 1].x) * 0.5
            let dy = (points[i + 1].y - points[i - 1].y) * 0.5
            tangents[i] = CGPoint(x: dx, y: dy)
        }
        
        for i in 0..<(n - 1) {
            let p1 = points[i]
            let p2 = points[i + 1]
            let t1 = tangents[i]
            let t2 = tangents[i + 1]
            
            let cp1 = CGPoint(x: p1.x + t1.x / 3.0, y: p1.y + t1.y / 3.0)
            let cp2 = CGPoint(x: p2.x - t2.x / 3.0, y: p2.y - t2.y / 3.0)
            
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
    }
}
