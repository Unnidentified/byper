//
// BatteryDropdownView.swift
// Native macOS Battery Menu Bar Companion App
//

import SwiftUI

// The popover's one checkmark. The caffeinate conditions, the app pickers, "Off on
// exit" and the settings automations all draw this, so the shape and the colour
// cannot drift apart.
struct PopoverCheckmark: View {
    let isOn: Bool
    // The abbreviation summary under each row title is drawn in the same brown
    // as a filled box, and it reads it from here so the two cannot drift apart.
    // It is one colour in every state: expanded or collapsed, one item armed or
    // four, the chip does not change.
    static let ink = BatteryDropdownView.checkmarkBrown
    var body: some View {
        Image(systemName: isOn ? "checkmark.square.fill" : "square")
            .font(.system(size: 11))
            .foregroundColor(isOn ? BatteryDropdownView.checkmarkBrown
                                  : BatteryDropdownView.checkmarkBrownDim)
    }
}

struct CheckmarkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: {
            configuration.isOn.toggle()
        }) {
            PopoverCheckmark(isOn: configuration.isOn)
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
// keeps only on-screen rows alive, so scrolling stays native-smooth even with a
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
    // Checkmark ink. Deliberately low contrast against the brown card: the
    // checkmark is meant to sit in the background, not to pop. Filled boxes use
    // the brighter brown, empty boxes the dimmer one, so the state still reads
    // from the fill and from a small brightness step.
    static let checkmarkBrown = Color(red: 0.42, green: 0.29, blue: 0.20)    // #6B4A33
    static let checkmarkBrownDim = Color(red: 0.33, green: 0.24, blue: 0.18) // #543D2E
    static let neonMintTeal = Color(red: 0.0, green: 0.95, blue: 0.72)   // #00F2B8 - "ACTIVE" Badge
    static let graphWarmSolar = Color(red: 0.96, green: 0.58, blue: 0.16) // #F59429 - Warm Solar Copper
    static let thermoAmber = Color(red: 1.0, green: 0.60, blue: 0.12)    // #FF991F - Temperature Icon

    // One dimming rule for every checkbox label in the popover: full white while
    // the box is checked, the same grey while it is not. The caffeinate rows,
    // "Off on exit" and the settings automations all read this, so the three
    // cannot drift into different greys. There is no explicit animation, exactly
    // like the caffeinate rows: a direct toggle is instant, and the master
    // slider's withAnimation still animates it.
    static func checkLabelColor(_ isOn: Bool) -> Color {
        isOn ? .white : Color(white: 0.62)
    }

    // The row's second line. It is absent while nothing is checked, so the row
    // keeps its old 16pt height, and it appears at a fixed 10pt the moment the
    // first box is ticked. The fixed height is what keeps the panel from
    // resizing as more items are added to a non-empty set.
    //
    // Every row draws its summary through here, so the chip colour is the
    // checkmark brown in all four rows and in every state. There is no colour
    // parameter on purpose: a call site cannot pick its own.
    @ViewBuilder
    private func rowSummary(_ text: String, identifier: String) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(.custom("FiraCode-Medium", size: 8.0))
                .foregroundColor(PopoverCheckmark.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: 10)
                .padding(.leading, 22)
                .accessibilityIdentifier(identifier)
        }
    }

    private var isBypassActive: Bool {
        return monitor.isPluggedIn && monitor.masterRowEnabled("bypass") &&
            (monitor.isHold || monitor.appliedPowerMode == .bypass ||
             (monitor.isTransitioning ? monitor.targetPowerMode == .bypass : monitor.powerMode == .bypass))
    }

    private var isLowPowerActive: Bool {
        return monitor.masterRowEnabled("lpm") && monitor.isLowPowerMode
    }

    private var isCaffeineActive: Bool {
        return monitor.masterRowEnabled("caffeine") && monitor.caffeineEngaged
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

    // One checkbox of the caffeinate dropdown. The four conditions are independent,
    // so this arms or disarms exactly one of them and leaves the other three alone.
    private func caffeineConditionRow(_ condition: BatteryMonitor.CaffeineCondition) -> some View {
        HStack(spacing: 6) {
            let armed = monitor.isCaffeineArmed(condition)
            Button(action: {
                monitor.setCaffeineArmed(condition, !armed)
                if condition == .app && !armed {
                    monitor.isCaffeineAppPickerExpanded = true
                    monitor.loadInstalledAppsIfNeeded()
                }
            }) {
                HStack(spacing: 6) {
                    PopoverCheckmark(isOn: armed)
                    Text(condition.label)
                        .font(.custom("FiraCode-Medium", size: 10.5))
                        .foregroundColor(Self.checkLabelColor(armed))
                    // The lid condition is the only one that needs a privileged
                    // switch, so it is the only one that can be armed and not
                    // effective. A marker rather than a word: the row has about
                    // 27pt left beside the label and "not active" needs 48.
                    if condition == .lidClose && monitor.lidSleepFailed {
                        Text("!")
                            .font(.custom("FiraCode-Bold", size: 9.0))
                            .foregroundColor(Color(red: 1.0, green: 0.30, blue: 0.30))
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(condition.label)
            .accessibilityValue(armed ? "on" : "off")

            // The picker belongs to the per-app condition, so its disclosure lives
            // on that row and nowhere else.
            if condition == .app {
                Button(action: {
                    monitor.isCaffeineAppPickerExpanded.toggle()
                    if monitor.isCaffeineAppPickerExpanded {
                        monitor.loadInstalledAppsIfNeeded()
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.custom("FiraCode-Bold", size: 8.5))
                        .foregroundColor(monitor.autoCaffeineBundleIds.isEmpty ? Color(white: 0.45) : Self.solarGold)
                        .rotationEffect(.degrees(monitor.isCaffeineAppPickerExpanded ? 90 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Caffeinate Apps")
                .padding(.trailing, 8)
            }
        }
        .frame(height: 16)
        .help(caffeineHelp(condition))
    }

    // One line per condition. The lid row is the only one whose text depends on
    // state: it is the only condition that needs a privileged switch, so it is
    // the only one that can be armed and not effective.
    private func caffeineHelp(_ condition: BatteryMonitor.CaffeineCondition) -> String {
        switch condition {
        case .bypass:
            return "Holds the display and idle sleep while a bypass hold is active"
        case .lidClose:
            return monitor.lidSleepFailed
                ? "Not active: the privileged byper CLI is missing or not setuid root"
                : "Holds system sleep off while armed, so the lid can shut without sleeping"
        case .charger:
            return "Holds the display and idle sleep while the charger is attached"
        case .app:
            return "Holds the display and idle sleep while a listed app is frontmost"
        }
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
                                .fill(Color.white.opacity(PopoverTuning.trackOpacity))
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

                        }
                    }
                    .frame(height: 4)
                    // Hairline: on a bright wallpaper the glass under the track
                    // is nearly white, and the track alone disappears into it.
                    .overlay(
                        Capsule()
                            .stroke(Color.black.opacity(PopoverTuning.trackHairlineOpacity),
                                    lineWidth: PopoverTuning.trackHairlineWidth)
                    )
                    // The left end eases out toward the rail's shoulder instead
                    // of stopping as a blunt capsule cap. The mask covers the
                    // hairline too, so the outline tapers with the fill.
                    .mask(ProgressTailMask())

                    Text("\(monitor.percentage)%")
                        .font(.custom("FiraCode-Bold", size: 10.5))
                        .foregroundColor(.primary)
                        // Sits on glass, so it needs its own contrast floor: the
                        // shell picks up the wallpaper behind it.
                        .shadow(color: Color.black.opacity(0.35), radius: 1.5, x: 0, y: 0.5)
                        
                    Spacer(minLength: 4)
                    
                    Button(action: {
                        // Quit = disable the app's effects now, remember them for
                        // the next launch: mark bypass state, resume charging,
                        // then terminate (init re-engages if it was active).
                        monitor.saveStateAndQuit()
                    }) {
                        Image(systemName: "power")
                            .font(.system(size: 10, weight: .bold))
                            // Sits on glass, so it takes the same contrast floor
                            // as the percentage instead of the dimmer secondary.
                            .foregroundColor(Color.white.opacity(0.8))
                            .shadow(color: Color.black.opacity(0.35), radius: 1.5, x: 0, y: 0.5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            // The line's top sits topBarTopInset below the shell body's top
            // edge. The shell already pads by contentPadding and the row is
            // taller than the line, so the row is pulled up by the difference;
            // the column shrinks by the same amount, which keeps the gap down
            // to the card and the rail.
            .padding(.top, -PopoverTuning.topBarPullUp)
            .padding(.trailing, PopoverTuning.topBarTrailingInset)

            HStack(alignment: .top, spacing: 12) {
                MasterPowerSwitch(monitor: monitor)
                    .frame(width: 32)

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
                    .padding(.top, 22)

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


                // Rounded enclosure: encompasses all the settings below the presets
                VStack(alignment: .leading, spacing: 4) {

                VStack(alignment: .leading, spacing: -2) {
                    let isBypass = (monitor.isTransitioning ? (monitor.targetPowerMode ?? monitor.powerMode) : monitor.powerMode) == .bypass
                    let isActive = isBypassActive
                    let iconName = isBypass ? "powerplug.fill" : "bolt.fill"
                    let iconColor = isBypass ? Self.coolBrownOrange : Self.emeraldGreen
                    
                    HStack(spacing: 4) {

                        Image(systemName: iconName)
                            .font(.custom("FiraCode-Regular", size: 10))
                            .foregroundColor(isActive ? iconColor : (isBypass ? iconColor.opacity(0.6) : Color(white: 0.38)))
                            .frame(width: 18, alignment: .center)

                        Text("Byper")
                            .font(.custom("FiraCode-SemiBold", size: 11))
                            .foregroundColor(isActive ? .white : (isBypass ? Color(white: 0.7) : Color(white: 0.38)))
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
                            get: { isBypass },
                            set: { val in
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
                        .disabled(!monitor.isPluggedIn || (!monitor.masterRowEnabled("bypass")))
                        .allowsHitTesting(monitor.masterRowEnabled("bypass"))
                    }
                    .frame(height: 16)

                    // The row's second line: the checked boxes' abbreviations,
                    // in check order. It collapses while nothing is checked, so
                    // the row is as tight as it was before the line existed.
                    rowSummary(monitor.bypassSummary,
                               identifier: "Bypass Summary")
                }
                .frame(height: monitor.bypassSummary.isEmpty ? 16 : 24)
                .masterRowProbe("bypass")

                if monitor.isBypassOptionsExpanded {
                    // Same shape as a caffeinate condition row: the checkmark
                    // leads at the dropdown's 22pt inset, the label follows at
                    // the same 6pt gap, and the label dims with the box. The
                    // checkmark used to sit at the trailing edge, 119pt right of
                    // the caffeinate boxes.
                    HStack(spacing: 6) {
                        Toggle("", isOn: $monitor.disableBypassOnQuit)
                            .labelsHidden()
                            .toggleStyle(CheckmarkToggleStyle())
                        Text("Off on exit")
                            .font(.custom("FiraCode-Medium", size: 10.5))
                            .foregroundColor(Self.checkLabelColor(monitor.disableBypassOnQuit))
                        Spacer(minLength: 4)
                    }
                    .padding(.leading, 22)
                    .frame(height: 16)
                    .allowsHitTesting(monitor.masterRowEnabled("bypass"))
                }




                VStack(alignment: .leading, spacing: -2) {
                    let isLPM = isLowPowerActive
                    HStack(spacing: 4) {
                        Image(systemName: "leaf.fill")
                            .font(.custom("FiraCode-Regular", size: 10))
                            .foregroundColor(isLPM ? Self.solarGold : Color(white: 0.38))
                            .frame(width: 18, alignment: .center)

                        Text("Powersave")
                            .foregroundColor(isLPM ? .white : Color(white: 0.38))
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
                                .foregroundColor(monitor.autoLPMPerApp ? Self.solarGold : Color(white: 0.45))
                                .rotationEffect(.degrees(monitor.isAppPickerExpanded ? 90 : 0))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Auto LPM Apps")
                        .padding(.trailing, 2)

                        Toggle("", isOn: Binding(
                            get: { isLPM },
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

                    // The row's second line: the per-app condition's
                    // abbreviation. It collapses while the box is unchecked, so
                    // the row is as tight as it was before the line existed.
                    rowSummary(monitor.lpmSummary,
                               identifier: "Powersave Summary")
                }
                .frame(height: monitor.lpmSummary.isEmpty ? 16 : 24)
                .allowsHitTesting(monitor.masterRowEnabled("lpm"))
                .masterRowProbe("lpm")

                if monitor.isAppPickerExpanded {
                    // Per-app submenu, the same shape as caffeinate's: an
                    // arming checkbox and a disclosure chevron at the dropdown's
                    // 22pt inset, and the app list nested under it with the same
                    // 4pt top pad and rounded background.
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            // The arming checkbox, the same shape as caffeinate's
                            // "Per app" row: the box arms the automation, the
                            // chevron opens the picker, and the selection is the
                            // picker's memory rather than the arming state.
                            Button(action: {
                                monitor.autoLPMPerApp.toggle()
                                if monitor.autoLPMPerApp {
                                    monitor.loadInstalledAppsIfNeeded()
                                }
                            }) {
                                HStack(spacing: 6) {
                                    PopoverCheckmark(isOn: monitor.autoLPMPerApp)
                                    Text("Per app")
                                        .font(.custom("FiraCode-Medium", size: 10.5))
                                        .foregroundColor(Self.checkLabelColor(monitor.autoLPMPerApp))
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Powersave Per App")
                            .accessibilityValue(monitor.autoLPMPerApp ? "on" : "off")

                            Button(action: {
                                monitor.isAppPickerSubmenuExpanded.toggle()
                                if monitor.isAppPickerSubmenuExpanded {
                                    monitor.loadInstalledAppsIfNeeded()
                                }
                            }) {
                                Image(systemName: "chevron.right")
                                    .font(.custom("FiraCode-Bold", size: 8.5))
                                    .foregroundColor(monitor.autoLPMPerApp ? Self.solarGold : Color(white: 0.45))
                                    .rotationEffect(.degrees(monitor.isAppPickerSubmenuExpanded ? 90 : 0))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Powersave Apps")
                            .padding(.trailing, 8)
                        }
                        .frame(height: 16)

                        if monitor.isAppPickerSubmenuExpanded {
                            AppPickerList(
                                apps: monitor.installedApps,
                                selectedIds: monitor.autoLPMBundleIds,
                                iconProvider: { monitor.icon(for: $0) },
                                onToggle: { id, enabled in
                                    monitor.setAutoLPMApp(id, enabled)
                                }
                            )
                            .equatable()
                            .frame(height: 160)
                            // Background first, then the gap: the other order
                            // put the 4pt pad inside the squircle and left a
                            // dead strip above the first row.
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                            .padding(.top, 4)
                        }
                    }
                    .padding(.leading, 22)
                    .allowsHitTesting(monitor.masterRowEnabled("lpm"))
                }


                // Caffeinate Menu: the switch is the manual always-on, the dropdown
                // holds the four independent conditions.
                // Negative spacing pulls the summary up under the title: the
                // title's line box carries 3pt of descender space below its ink,
                // so a positive gap reads as a detached line rather than a
                // subtitle. Measured ink gap is 3pt.
                VStack(alignment: .leading, spacing: -2) {
                    let isCaff = isCaffeineActive
                    HStack(spacing: 4) {
                        Image(systemName: "display")
                            .font(.custom("FiraCode-Regular", size: 10))
                            .foregroundColor(isCaff ? Self.solarGold : Color(white: 0.38))
                            .frame(width: 18, alignment: .center)

                        Text("Caffeinate")
                            .font(.custom("FiraCode-SemiBold", size: 11))
                            .foregroundColor(isCaff ? .white : Color(white: 0.38))

                        Spacer()

                        Button(action: {
                            monitor.isCaffeineMenuExpanded.toggle()
                        }) {
                            Image(systemName: "chevron.right")
                                .font(.custom("FiraCode-Bold", size: 8.5))
                                .foregroundColor(monitor.caffeineArmedConditions.isEmpty ? Color(white: 0.38) : Self.solarGold)
                                .rotationEffect(.degrees(monitor.isCaffeineMenuExpanded ? 90 : 0))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Caffeinate Options")
                        .padding(.trailing, 2)

                        // The manual switch. It is the always-on override, not a
                        // condition: it reads and writes byp_caffeine_always_on
                        // alone, so a condition engaging never moves it and turning
                        // it off never disarms a condition.
                        Toggle("", isOn: $monitor.caffeineAlwaysOn)
                            .labelsHidden()
                            .scaleEffect(0.70, anchor: .trailing)
                            // same Docked-right alignment as the bypass row (see comment there)
                            .frame(width: 26.6, alignment: .trailing)
                            .toggleStyle(SmoothSwitchToggleStyle(tint: Self.solarGold))
                            .padding(.trailing, 5)
                            .accessibilityLabel("Caffeinate Switch")
                    }
                    // The switch's unscaled layout box is 22pt tall, which would
                    // inflate this line and push the summary 5.5pt clear of the
                    // title. Pin the line to the same 16pt the other rows use so
                    // the summary reads as part of the row.
                    .frame(height: 16)

                    // The armed set gets its own line. The row has about 26pt of
                    // free width beside the title, which is not enough for one
                    // condition name, let alone four. The height is fixed, so
                    // arming a condition never resizes the panel.
                    rowSummary(monitor.caffeineSummary,
                               identifier: "Caffeinate Summary")
                }
                // 16pt title line, minus the 2pt pull, plus the 10pt summary line.
                // Tight enough to keep the same rhythm as the rows above, fixed so
                // arming a condition never resizes the panel.
                .frame(height: 24)
                .allowsHitTesting(monitor.masterRowEnabled("caffeine"))
                .masterRowProbe("caffeine")

                if monitor.isCaffeineMenuExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(BatteryMonitor.CaffeineCondition.allCases, id: \.self) { condition in
                            caffeineConditionRow(condition)
                        }
                        // Shown whenever the chevron is open, like the Low Power
                        // Mode picker: the chevron must never be a dead control,
                        // and the selection is worth editing before arming.
                        if monitor.isCaffeineAppPickerExpanded {
                            AppPickerList(
                                apps: monitor.installedApps,
                                selectedIds: monitor.autoCaffeineBundleIds,
                                iconProvider: { monitor.icon(for: $0) },
                                onToggle: { id, enabled in
                                    if enabled {
                                        monitor.autoCaffeineBundleIds.insert(id)
                                    } else {
                                        monitor.autoCaffeineBundleIds.remove(id)
                                    }
                                }
                            )
                            .equatable()
                            .frame(height: 160)
                            // Background first, then the gap: the other order
                            // put the 4pt pad inside the squircle and left a
                            // dead strip above the first row.
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                            .padding(.top, 4)
                        }
                    }
                    .padding(.leading, 22)
                    // Pull the list up under the row. The row already ends just
                    // below the summary, so the parent's 4pt stack spacing leaves
                    // the first checkbox floating clear of it.
                    .padding(.top, -3)
                    .allowsHitTesting(monitor.masterRowEnabled("caffeine"))
                }


                VStack(alignment: .leading, spacing: -2) {
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

                    // The row's second line: the checked automations'
                    // abbreviations, in check order. It collapses while nothing
                    // is checked, so the row is as tight as it was before the
                    // line existed.
                    rowSummary(monitor.settingsSummary,
                               identifier: "Settings Summary")
                }
                .frame(height: monitor.settingsSummary.isEmpty ? 16 : 24)
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
                                        .foregroundColor(Self.checkLabelColor(monitor.autoHoldOnPlug))
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { monitor.autoHoldOnPlug },
                                    set: { monitor.setSettingsArmed(.connect, $0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(CheckmarkToggleStyle())
                            }

                            Divider().background(Color.white.opacity(0.08))

                            // Automation 2: Launch / Bypass at Login
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Auto Bypass at Login")
                                        .font(.custom("FiraCode-Medium", size: 10.5))
                                        .foregroundColor(Self.checkLabelColor(monitor.autoHoldAtLogin))
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { monitor.autoHoldAtLogin },
                                    set: { monitor.setSettingsArmed(.login, $0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(CheckmarkToggleStyle())
                            }

                            Divider().background(Color.white.opacity(0.08))

                            // Automation 3: External Display
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Auto Bypass on Display")
                                        .font(.custom("FiraCode-Medium", size: 10.5))
                                        .foregroundColor(Self.checkLabelColor(monitor.autoHoldOnDisplay))
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { monitor.autoHoldOnDisplay },
                                    set: { monitor.setSettingsArmed(.display, $0) }
                                ))
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
                // Report the enclosure's vertical bounds in masterZone space so the
                // master rail can clamp itself to exactly this height (it used to
                // overhang the enclosure top and bottom).
                .background(GeometryReader { g in
                    Color.clear.preference(key: MasterRowYKey.self, value: [
                        "::enctop": g.frame(in: .named("masterZone")).minY,
                        "::encbottom": g.frame(in: .named("masterZone")).maxY,
                    ])
                })
                .padding(.top, PopoverTuning.cardTopPadding)
                // Master fade covers the whole menu column (graph labels → presets → enclosure)
                // so the grey line reaches every element in top-down order, presets included.
                //
                // It sits INSIDE the card, before .sunkenCard(), so the mask only ever
                // touches the content. Wrapping the card instead masked its own fill too:
                // the 0.45 top stop made the panel 45% opaque, so the glass and the
                // wallpaper behind it showed through and the brown turned grey.
                //
                // The gradient is relative to the bounds of the view it is applied to.
                // Here that is the padded menu column, which is exactly the card's
                // bounds (the 6pt top padding is already applied and .sunkenCard() adds
                // no layout), so the grey line still lands on the knob.
                .modifier(MasterFadeModifier(level: monitor.masterLevel))
                // The hairline is card chrome, not content, so it sits outside the
                // fade: inside it, it was masked down to 45% above the knob. Its
                // colour now fades to nothing at the top, so it no longer draws a
                // second edge 6 pt below the card's top. The warm wash that used to
                // sit here is a fill of the card's own shape in SunkenCard, so it
                // has no edge of its own either.
                //
                // The radius and the top inset stay: they are what lands the
                // hairline's bottom on the card's bottom edge, where it pairs with
                // the rim light. The fade is what takes it off the top.
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(PopoverTuning.cardHairline, lineWidth: 1)
                        .padding(.top, PopoverTuning.cardTopPadding)
                )
                // Inner card: opaque, sits on the glass like an inset panel. No
                // inset padding, so the content keeps the width it had before
                // the card existed and nothing truncates.
                .sunkenCard()
                }
                .background(GeometryReader { g in
                      Color.clear.preference(key: MasterRowYKey.self, value: ["::height": g.size.height])
                })
                .coordinateSpace(name: "masterZone")
                .onPreferenceChange(MasterRowYKey.self) { monitor.updateMasterRowGeometry($0) }
            }

        .onTapGesture {
            // Clicking any non-interactive area cancels an open rename editor
            monitor.renamingPreset = nil
        }
        .padding(PopoverTuning.contentPadding)
        .frame(width: PopoverTuning.shellWidth)
        .fixedSize(horizontal: true, vertical: false)
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
        // The rail lives entirely inside this column. The column's top is the
        // card's top edge, so the rail is already flush with the card without
        // any negative inset. Pushing it above the column put the capsule cap
        // and the knob outside the container, where the clip cut them flat.
        let topInset: CGFloat = 0
        let bottomInset: CGFloat = 0
        let railHeight = max(0, geo.size.height - topInset - bottomInset)
        let travel = max(0, railHeight - knob - 8)
        let level = monitor.masterLevel
        let knobY = 4 + (1 - level) * travel
        let fillTop = max(0, knobY - (level > 0.9 ? 4 * CGFloat((level - 0.9) / 0.1) : 0))
        let fillHeight = max(geo.size.width, railHeight - fillTop)
        let brownFill = Color(red: 114/255.0, green: 48/255.0, blue: 21/255.0) // #723015

        ZStack(alignment: .top) {
            // The rail carries no master fade. It is a control, not content, and
            // its knob already shows the level. The fade's top stop is 45%
            // opaque, so the rail's rounded cap was composited at 45% and the
            // glass showed through it as a soft dark cap above the slider.
            ZStack(alignment: .top) {
                // Track background (dark charcoal)
                Capsule()
                    .fill(Color(white: 0.16))

                // Active brown fill-in (#723015), rounded at top and bottom, moving in lockstep with the ball
                Capsule()
                    .fill(brownFill)
                    .frame(width: geo.size.width, height: fillHeight)
                    .offset(y: fillTop)
                    .opacity(level > 0.001 ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Slider ball (knob)
            Circle()
                .fill(level > 0.001 ? Color(red: 0.78, green: 0.58, blue: 0.48) : Color(white: 0.60))
                .frame(width: knob, height: knob)
                // Subtle inner depth only: a drop shadow here spilled past the rail's
                // rounded cap and read as a warm halo around the slider tip.
                .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 1))
                .offset(y: knobY)
        }
        .clipShape(Capsule())
        .frame(width: geo.size.width, height: railHeight)
        .offset(y: topInset)
        .animation(.spring(response: 0.30, dampingFraction: 0.7), value: monitor.masterLevel)
        .contentShape(Rectangle())
        .gesture(
            // Drag anywhere on the rail to set the level; a quick tap snaps to the nearest end
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    monitor.isDraggingMaster = true
                    guard !monitor.isTransitioning else { return }
                    let travel = max(1, railHeight - 28)
                    let frac = 1 - min(max((g.location.y - topInset - 14) / travel, 0), 1)
                    monitor.setMasterLevel(frac > 0.9 ? 1 : frac)
                  }
                  .onEnded { g in
                      guard !monitor.isTransitioning else { monitor.finishMasterDrag(); return }
                      let travel = max(1, railHeight - 28)
                    let frac = 1 - min(max((g.location.y - topInset - 14) / travel, 0), 1)
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
// interpolation, so the enclosure rows use this drawn style instead: same look, spring glide.
struct SmoothSwitchToggleStyle: ToggleStyle {
    var tint: Color
    // onTapGesture does NOT honor the .disabled() environment. Without this
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
                  // number bobs at just 40% of the dot's travel, steadier than the dot
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
