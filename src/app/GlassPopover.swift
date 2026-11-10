//
// GlassPopover.swift
// Native macOS Battery Menu Bar Companion App
//
// The popover shell. A borderless panel hosts the SwiftUI content and draws the
// shell as one notched outline: on macOS 26 and later that outline is Liquid
// Glass, everywhere else it is the solid dark shell the app has always used.
//

import AppKit
import QuartzCore
import SwiftUI

// MARK: - Tuning
//
// Every number the shell cares about lives here. Change one, rebuild, done.

enum PopoverTuning {
    // Shell body
    static let shellWidth: CGFloat = 244
    // Concentric with the card: cardCornerRadius 15 plus the contentPadding 11
    // gutter the card sits in gives 26. The old 20 was 6 pt tighter than that,
    // so the shell's arc and the card's arc did not share a centre.
    static let cornerRadius: CGFloat = 26
    static let contentPadding: CGFloat = 11

    // Notch (the tab that points at the menu bar icon). Its proportions live in
    // PopoverTuning+Outline.swift, next to the path that draws them.

    // Shell finish. One switch, two presets.
    //   .clear  brown tint 0.20. A touch darker and warmer than bare glass,
    //           still transparent enough to take the wallpaper.
    //   .dark   brown tint 0.45. Keeps the old dark look on light wallpapers.
    // The system setting Appearance > Liquid Glass > Clear / Tinted stacks on
    // top of this, so both presets have to hold up in both modes.
    enum ShellStyle {
        case clear
        case dark
    }

    static let shellStyle: ShellStyle = .clear

    // The tint colour. A saturated dark brown, deliberately not the card fill.
    // The card fill is almost neutral (R minus B is 14 levels), so at 20% over
    // a cool wallpaper it pulled the glass back toward grey: measured R minus B
    // went from -9 before the tint to -4 after it. This colour keeps the old
    // tint's luminance (0.118 against 0.113), so the shell darkens by the same
    // amount, but its R minus B is 74 levels instead of 14, so the glass reads
    // warm instead of neutral. This is the one knob: change it to retint the
    // glass.
    static let glassTintColor = Color(red: 0.300, green: 0.075, blue: 0.010)

    // How much of that brown the glass takes. Low on purpose: the tint darkens
    // the shell, it does not make it opaque, so the wallpaper still shows
    // through and still refracts.
    static var glassTintOpacity: Double {
        switch shellStyle {
        case .clear: return 0.20
        case .dark: return 0.45
        }
    }
    static var glassTint: Color { glassTintColor.opacity(glassTintOpacity) }

    // Top bar sits on the glass, so its track needs a floor that survives a
    // bright wallpaper. The hairline separates the track from the glass where
    // the glass is nearly white.
    static var trackOpacity: Double {
        switch shellStyle {
        case .clear: return 0.22
        case .dark: return 0.18
        }
    }
    static let trackHairlineOpacity: Double = 0.15
    static let trackHairlineWidth: CGFloat = 0.5

    // Inner card. Opaque on purpose: it sits on the glass, it is not part of it.
    // The fill is the old popover wash composited flat (0.11/0.10/0.10 base plus
    // the #782800 wash at 10%), so the card looks exactly as it did before.
    static let cardCornerRadius: CGFloat = 15
    static let cardFill = Color(red: 0.146, green: 0.106, blue: 0.090)
    // Space between the card's top edge and its first row. The master rail
    // reads it so the two tops line up.
    static let cardTopPadding: CGFloat = 6

    // Sunken card. Light comes from above, so the shadow sits inside the top
    // edge and the light sits on the bottom lip. No outer drop shadow.
    static let innerShadowOpacity: Double = 0.45
    static let innerShadowRadius: CGFloat = 6
    static let innerShadowOffsetY: CGFloat = 3
    static let rimShadowOpacity: Double = 0.40
    static let rimLightOpacity: Double = 0.30
    // How far in from each side the rim fades out before it reaches the edge.
    static let rimFadeInset: CGFloat = 0.16

    // Status item selection pill. AppKit draws its own pill only while the
    // button is tracking, so the open state needs one of ours. The system's
    // pill is 46 x 24 pt around a 41.5 x 22 pt button, but the item's window is
    // only 42 pt wide, so a 46 pt pill is clipped into a flat-ended rectangle
    // and stops reading as a capsule. The pill is therefore sized to the
    // window: 42 x 24 pt, which keeps both caps round.
    static let pillOverhangX: CGFloat = 0.25
    static let pillOverhangY: CGFloat = 1
    // The system's press pill is a flat wash, not a translucent one: measured
    // over 520 interior samples it renders (209, 215, 220) with a std of 0.55
    // while the menu bar under it varies with a std of 2.40, so it tracks only
    // 18% of the bar's gradient. A translucent fill tracks 100% of it and lands
    // 3 to 5 levels darker. The value below is interpolated from two measured
    // sRGB inputs (184 -> 175, 221 -> 216) so it renders as that grey.
    static let pillLightFill = NSColor(srgbRed: 215.0 / 255.0,
                                       green: 220.0 / 255.0,
                                       blue: 224.0 / 255.0,
                                       alpha: 1)
    // Dark menu bar. Unmeasured on this machine, whose bar is light, so the
    // old translucent white stays until a capture of a dark bar exists.
    static let pillFillOpacity: CGFloat = 0.10

    // Fallback shell: macOS before 26, or Reduce Transparency.
    static let solidShell = Color(red: 0.11, green: 0.10, blue: 0.10)

    // Panel placement
    static let screenMargin: CGFloat = 8

    // Close animation
    static let closeDuration: Double = 0.13
    static let closeDurationReduceMotion: Double = 0.10

    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - Notched outline
//
// One closed path: rounded body plus the tab rising out of its top edge. The
// notch is spliced into the top edge rather than added as a second subpath, so
// the glass rim runs around the tab without a seam across its base.

struct NotchedRoundedRect: Shape, Animatable {
    var cornerRadius: CGFloat = PopoverTuning.cornerRadius
    // Almost square, so the top-right corner does not read as a second body
    // corner. Continuous rather than circular: see the corner code below.
    var topRightRadius: CGFloat = PopoverTuning.topRightCornerRadius
    var notchCenterX: CGFloat = PopoverTuning.shellWidth / 2

    var animatableData: CGFloat {
        get { notchCenterX }
        set { notchCenterX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()

        let nh = min(PopoverTuning.notchCaretHeight, rect.height / 2)
        let top = rect.minY + nh
        let bottom = rect.maxY
        let left = rect.minX
        let right = rect.maxX
        let r = max(0, min(cornerRadius, min(rect.width, bottom - top) / 2))
        let tr = max(0, min(topRightRadius, min(rect.width, bottom - top) / 2))

        // Notch proportions. The base is where the flank lines meet the top
        // edge; the shoulder fillets start a little further out, so the flat
        // part of the top edge is a touch wider than the base.
        let halfBase = max(1, min(PopoverTuning.notchBaseWidth / 2, rect.width / 2 - r - 2))
        let tipRadius = max(0.5, PopoverTuning.notchTipRadius)
        let fillet = max(0.5, PopoverTuning.notchShoulderFillet)

        // Keep the tab clear of the body's corner arcs: the shoulder starts at
        // the point where the top edge stops being an arc.
        let minCX = left + r + halfBase + fillet
        let maxCX = right - r - halfBase - fillet
        let cx = maxCX > minCX ? min(max(notchCenterX, minCX), maxCX) : rect.midX

        // Flank direction. The flank leaves the base corner and runs tangent to
        // the tip circle, whose centre sits one tip radius below the top of the
        // rect so the arc's crown lands exactly on rect.minY. Solving for the
        // tangent gives the direction, so the apex angle falls out of the base,
        // the height and the tip radius instead of being set directly.
        let rise = max(0.001, nh - tipRadius)
        let d2 = halfBase * halfBase + rise * rise
        let tangent = max(0, d2 - tipRadius * tipRadius).squareRoot()
        let ux = max(0.001, min(1, (-tipRadius * rise + halfBase * tangent) / d2))
        let uy = max(0.001, min(1, (tipRadius + rise * ux) / halfBase))
        let len = (ux * ux + uy * uy).squareRoot()
        let fx = ux / len
        let fy = uy / len

        // Both arcs sweep the angle between the top edge and the flank, so one
        // control offset serves the tip and the shoulders.
        let sweep = atan2(fy, fx)
        let arcK = 4.0 / 3.0 * tan(sweep / 4)

        // Tip arc: centre one tip radius below the crown, tangent points where
        // the flanks touch it.
        let tipY = rect.minY + tipRadius
        let tipLeft = CGPoint(x: cx - tipRadius * fy, y: tipY - tipRadius * fx)
        let tipRight = CGPoint(x: cx + tipRadius * fy, y: tipY - tipRadius * fx)
        let crown = CGPoint(x: cx, y: rect.minY)

        // Shoulder fillets: circles of radius fillet tangent to the top edge and
        // to the flank, so the shoulder leaves the top edge horizontally and
        // joins the flank along its own direction.
        let shoulderRun = fillet * (1 - fx) / fy
        let leftShoulder = CGPoint(x: cx - halfBase - shoulderRun, y: top)
        let leftJoin = CGPoint(x: leftShoulder.x + fillet * fy,
                               y: top - fillet + fillet * fx)
        let rightShoulder = CGPoint(x: cx + halfBase + shoulderRun, y: top)
        let rightJoin = CGPoint(x: rightShoulder.x - fillet * fy,
                                y: top - fillet + fillet * fx)

        // Top-right corner: continuous, so it starts 1.5 radii before the corner
        // and leaves the top edge with zero curvature instead of a circular
        // arc's sudden bend. Two cubics meet on the diagonal, where the
        // curvature is highest.
        let lead = tr * 1.5
        let diag = tr * 0.25
        let ctrl = (lead - 2 * diag) / 2

        // Circle-to-Bezier constant, so the corners stay circular without
        // depending on arc winding in a flipped coordinate space.
        let k: CGFloat = 0.5522847498

        p.move(to: CGPoint(x: left + r, y: top))

        // Top edge, up to the notch's left shoulder.
        p.addLine(to: leftShoulder)
        p.addCurve(to: leftJoin,
                   control1: CGPoint(x: leftShoulder.x + arcK * fillet, y: top),
                   control2: CGPoint(x: leftJoin.x - arcK * fillet * fx,
                                     y: leftJoin.y + arcK * fillet * fy))

        // Left flank, rounded tip, right flank.
        p.addLine(to: tipLeft)
        p.addCurve(to: crown,
                   control1: CGPoint(x: tipLeft.x + arcK * tipRadius * fx,
                                     y: tipLeft.y - arcK * tipRadius * fy),
                   control2: CGPoint(x: crown.x - arcK * tipRadius, y: crown.y))
        p.addCurve(to: tipRight,
                   control1: CGPoint(x: crown.x + arcK * tipRadius, y: crown.y),
                   control2: CGPoint(x: tipRight.x - arcK * tipRadius * fx,
                                     y: tipRight.y - arcK * tipRadius * fy))
        p.addLine(to: rightJoin)
        p.addCurve(to: rightShoulder,
                   control1: CGPoint(x: rightJoin.x + arcK * fillet * fx,
                                     y: rightJoin.y + arcK * fillet * fy),
                   control2: CGPoint(x: rightShoulder.x - arcK * fillet, y: top))

        // Top edge, on to the top-right corner.
        p.addLine(to: CGPoint(x: right - lead, y: top))
        p.addCurve(to: CGPoint(x: right - diag, y: top + diag),
                   control1: CGPoint(x: right - lead + ctrl, y: top),
                   control2: CGPoint(x: right - 2 * diag, y: top))
        p.addCurve(to: CGPoint(x: right, y: top + lead),
                   control1: CGPoint(x: right, y: top + 2 * diag),
                   control2: CGPoint(x: right, y: top + lead - ctrl))

        // Right side, bottom-right corner.
        p.addLine(to: CGPoint(x: right, y: bottom - r))
        p.addCurve(to: CGPoint(x: right - r, y: bottom),
                   control1: CGPoint(x: right, y: bottom - r + k * r),
                   control2: CGPoint(x: right - r + k * r, y: bottom))

        // Bottom edge, bottom-left corner.
        p.addLine(to: CGPoint(x: left + r, y: bottom))
        p.addCurve(to: CGPoint(x: left, y: bottom - r),
                   control1: CGPoint(x: left + r - k * r, y: bottom),
                   control2: CGPoint(x: left, y: bottom - r + k * r))

        // Left side, top-left corner.
        p.addLine(to: CGPoint(x: left, y: top + r))
        p.addCurve(to: CGPoint(x: left + r, y: top),
                   control1: CGPoint(x: left, y: top + r - k * r),
                   control2: CGPoint(x: left + r - k * r, y: top))

        p.closeSubpath()
        return p
    }
}

// MARK: - Shell

struct GlassShell<Content: View>: View {
    var notchCenterX: CGFloat
    var content: Content

    init(notchCenterX: CGFloat, @ViewBuilder content: () -> Content) {
        self.notchCenterX = notchCenterX
        self.content = content()
    }

    private var shape: NotchedRoundedRect {
        NotchedRoundedRect(
            cornerRadius: PopoverTuning.cornerRadius,
            notchCenterX: notchCenterX
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            shell
            content
                // The body's top edge sits the caret's height below the panel
                // top, so the content starts there. It used to read notchHeight,
                // which stopped matching the path once the caret grew.
                .padding(.top, PopoverTuning.notchCaretHeight)
        }
        // The panel is non-opaque, so the whole notched outline has to be a hit
        // target. Without this, clicks on the glass between controls fall
        // through to whatever is behind the window.
        .contentShape(shape)
    }

    @ViewBuilder
    private var shell: some View {
        if #available(macOS 26.0, *), !PopoverTuning.reduceTransparency {
            Color.clear
                .glassEffect(.regular.tint(PopoverTuning.glassTint), in: shape)
                // The glass paints its backdrop over the whole view bounds and
                // the `in:` shape only clips the tint, so the window frame shows
                // through as a flat rectangle with square corners around the
                // rounded shell. Clipping the layer stack to the same outline
                // removes it.
                .clipShape(shape)
        } else {
            shape.fill(PopoverTuning.solidShell)
        }
    }
}

// MARK: - Anchor

/// Where the notch points, in the shell's own coordinate space. The panel
/// updates it on every show so the arrow tracks the status item even when the
/// panel itself had to be clamped to the screen edge.
final class PopoverAnchor: ObservableObject {
    @Published var notchCenterX: CGFloat = PopoverTuning.shellWidth / 2
    var onSizeChange: ((CGSize) -> Void)?
}

private struct PopoverSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 { value = next }
    }
}

struct PopoverRoot<Content: View>: View {
    @ObservedObject var anchor: PopoverAnchor
    var content: Content

    var body: some View {
        GlassShell(notchCenterX: anchor.notchCenterX) {
            content
        }
        .background(
            GeometryReader { g in
                Color.clear.preference(key: PopoverSizeKey.self, value: g.size)
            }
        )
        .onPreferenceChange(PopoverSizeKey.self) { anchor.onSizeChange?($0) }
        .ignoresSafeArea()
    }
}

// MARK: - Sunken card
//
// The card sits in the glass rather than on it: shadow inside the top edge,
// light on the bottom lip, nothing on the outside. Kept as its own modifier so
// the view that uses it stays inside the type checker's budget.

struct SunkenCard: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PopoverTuning.cardCornerRadius, style: .continuous)
    }

    /// Inner shadow without `.shadow(.inner:)`, which needs macOS 13 and this
    /// app still targets 11.
    ///
    /// A ring between the card's own outline and the card inset by the blur
    /// radius, blurred in place. The old version stroked a shape expanded past
    /// the edge and pushed it down, which moved the arc's centre and left a
    /// second rounded rectangle visible at the top corners. This one uses the
    /// card's arc, so the shadow and the rim line up exactly. The blur is at
    /// least the ring's width, so the ring's inner boundary has no hard edge.
    private var innerShadow: some View {
        GeometryReader { g in
            let rect = CGRect(origin: .zero, size: g.size)
            let r = PopoverTuning.innerShadowRadius
            let outer = RoundedRectangle(cornerRadius: PopoverTuning.cardCornerRadius,
                                         style: .continuous)
                .path(in: rect)
            let inner = RoundedRectangle(cornerRadius: max(0, PopoverTuning.cardCornerRadius - r),
                                         style: .continuous)
                .path(in: rect.insetBy(dx: r, dy: r))
            var ring = Path()
            ring.addPath(outer)
            ring.addPath(inner)
            return ring
                .fill(shadowGradient, style: FillStyle(eoFill: true))
                .blur(radius: r * PopoverTuning.innerShadowBlurScale)
                .mask(shape.fill(Color.black))
        }
    }

    /// Light comes from above, so the shadow is strongest along the top edge and
    /// gone by the bottom. The slight lean toward the leading edge keeps the
    /// left side a touch darker than the right.
    private var shadowGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(PopoverTuning.innerShadowOpacity), location: 0),
                .init(color: .black.opacity(PopoverTuning.innerShadowOpacity * 0.30), location: 0.45),
                .init(color: .clear, location: 0.85)
            ],
            startPoint: .topLeading,
            endPoint: .bottom
        )
    }

    /// The wash is a fill of the card's own shape, so it has no edge. It sits
    /// under the shadow rather than over it, which keeps the shadow's strength.
    private var background: some View {
        ZStack {
            shape.fill(PopoverTuning.cardFill)
            shape.fill(PopoverTuning.cardWash)
            innerShadow
        }
    }

    private var rimGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(PopoverTuning.rimShadowOpacity), location: 0),
                .init(color: .clear, location: 0.5),
                .init(color: .white.opacity(PopoverTuning.rimLightOpacity), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Both ends of the rim fade out, so the hairline never stops dead at the
    /// card's left and right edges.
    private var rimFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: PopoverTuning.rimFadeInset),
                .init(color: .white, location: 1 - PopoverTuning.rimFadeInset),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// One hairline hugging the card's edge: dark at the top, light at the
    /// bottom, fading out at both ends.
    ///
    /// It sits just inside the edge rather than just outside. A stroke on a
    /// shape inset outward paints past the view's bounds, and `.mask` clips to
    /// the bounds, which erased it. Inset by 1 the stroke lands inside, the mask
    /// works, and the arc keeps the card's centre so it stays concentric with
    /// the inner shadow.
    private var rim: some View {
        shape
            .inset(by: 1)
            .stroke(rimGradient, lineWidth: 1)
            .mask(rimFade)
    }

    func body(content: Content) -> some View {
        content
            .background(background)
            .overlay(rim)
    }
}

extension View {
    func sunkenCard() -> some View { modifier(SunkenCard()) }
}

// MARK: - Status item pill
//
// The selection pill behind the menu bar icon. AppKit draws its own only while
// the button is tracking, and neither `highlight(_:)` nor `state = .on` makes it
// persist, so the open state gets one of ours. It lives in the item's container
// view, behind the button, and overhangs it by the same amount the system pill
// does. It never takes clicks: the overhang reaches into the neighbouring items.

final class StatusPillView: NSView {
    /// True when the menu bar is dark, so its ink is light. It is set from the
    /// same vibrant-only signal the icon uses. The old pill filled with
    /// NSColor.labelColor inside draw(_:), which resolves against this view's
    /// own effective appearance, and that value passes through plain Aqua on
    /// every click of the status item. One draw in that window paints black at
    /// 10% on a dark bar, which reads as a flicker.
    var barIsDark: Bool = true {
        didSet { if oldValue != barIsDark { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color: NSColor = barIsDark
            ? NSColor(white: 1, alpha: PopoverTuning.pillFillOpacity)
            : PopoverTuning.pillLightFill
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = bounds.height / 2
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

// MARK: - Panel

final class PopoverPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PopoverTuning.shellWidth, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // The window shadow is derived from the window's alpha channel. A glass
        // shell is only partly opaque, so AppKit falls back to a rectangular
        // mask and paints a hard square behind the rounded corners (visible at
        // the bottom left). invalidateShadow() does not correct it, so the
        // shadow is off and the glass supplies its own depth.
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Controller

final class PopoverPanelController: NSObject {
    /// One click, one transition. `closing` is its own state so a click that
    /// lands mid-animation can reopen instead of racing the pending orderOut.
    private enum Phase {
        case closed, opening, open, closing
    }

    let panel = PopoverPanel()
    let anchor: PopoverAnchor

    private let hosting: NSHostingController<PopoverRoot<AnyView>>
    private var insideMonitor: Any?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private weak var anchorButton: NSStatusBarButton?

    private var phase: Phase = .closed
    private var closeToken = 0
    private var pillView: StatusPillView?

    /// Menu bar tone for the pill. AppDelegate feeds it from the button's
    /// vibrant appearance, the same signal the icon follows.
    var menuBarIsDark: Bool = true {
        didSet { pillView?.barIsDark = menuBarIsDark }
    }

    var onShow: (() -> Void)?
    var onClose: (() -> Void)?

    init<Content: View>(@ViewBuilder content: () -> Content) {
        let anchor = PopoverAnchor()
        self.anchor = anchor
        self.hosting = NSHostingController(
            rootView: PopoverRoot(anchor: anchor, content: AnyView(content()))
        )
        super.init()

        anchor.onSizeChange = { [weak self] size in self?.contentSizeChanged(size) }

        panel.contentViewController = hosting
        panel.onCancel = { [weak self] in self?.close() }

        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Shows or hides the selection pill behind the status item. The pill is
    /// ours, so it changes exactly once per open and once per close and cannot
    /// be cleared by the status item's tracking loop.
    private func setPill(_ on: Bool) {
        guard let button = anchorButton else { return }
        if pillView == nil, let container = button.superview {
            let pill = StatusPillView(frame: pillFrame(for: button))
            pill.autoresizingMask = []
            pill.barIsDark = menuBarIsDark
            pill.isHidden = true
            container.addSubview(pill, positioned: .below, relativeTo: button)
            pillView = pill
        }
        pillView?.frame = pillFrame(for: button)
        pillView?.isHidden = !on
    }

    private func pillFrame(for button: NSStatusBarButton) -> NSRect {
        button.frame.insetBy(dx: -PopoverTuning.pillOverhangX, dy: -PopoverTuning.pillOverhangY)
    }

    private var phaseName: String {
        switch phase {
        case .closed: return "closed"
        case .opening: return "opening"
        case .open: return "open"
        case .closing: return "closing"
        }
    }

    // MARK: Show / close

    func toggle(relativeTo button: NSStatusBarButton) {
        switch phase {
        case .closed:
            show(relativeTo: button)
        case .opening, .open:
            close()
        case .closing:
            // A click during the close animation reopens from the current
            // state. The pending orderOut is cancelled by the token bump.
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        let wasClosing = (phase == .closing)
        closeToken += 1
        phase = .opening
        anchorButton = button
        setPill(true)

        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let size = NSSize(
            width: max(fitting.width, PopoverTuning.shellWidth),
            height: max(fitting.height, 1)
        )
        place(size: size, under: button)

        if wasClosing {
            // A fade is still running and would finish at alpha 0 behind our
            // back. A zero-duration group on the same key path replaces it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
        }
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        onShow?()
        phase = .open
    }

    func close() {
        guard phase == .open || phase == .opening else { return }
        phase = .closing
        closeToken += 1
        let token = closeToken

        removeMonitors()
        // The pill goes out when the close starts, not when it ends.
        setPill(false)
        onClose?()

        let duration = PopoverTuning.reduceMotion
            ? PopoverTuning.closeDurationReduceMotion
            : PopoverTuning.closeDuration

        // Window-level fade. Animating opacity on the glass view inside SwiftUI
        // flashes and drops the glass, so the window owns the animation.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.closeToken == token else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.phase = .closed
        })
    }

    /// Re-measures the SwiftUI content and resizes the panel, keeping the top
    /// edge (and therefore the notch) pinned to the menu bar.
    func refit() {
        guard panel.isVisible else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        guard fitting.height > 1 else { return }
        resize(to: NSSize(width: max(fitting.width, PopoverTuning.shellWidth), height: fitting.height))
    }

    // MARK: Geometry

    private func contentSizeChanged(_ size: CGSize) {
        guard panel.isVisible, size.height > 1 else { return }
        let target = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard abs(target.height - panel.frame.height) > 0.5 ||
              abs(target.width - panel.frame.width) > 0.5 else { return }
        // Deferred: the preference lands mid-layout, and moving the window from
        // inside that pass re-enters SwiftUI.
        DispatchQueue.main.async { [weak self] in
            self?.resize(to: target)
        }
    }

    private func resize(to size: NSSize) {
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        panel.setFrame(frame, display: true)
        updateNotch()
    }

    private func place(size: NSSize, under button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let full = screen?.frame ?? .zero

        var x = buttonRect.midX - size.width / 2
        let minX = full.minX + PopoverTuning.screenMargin
        let maxX = full.maxX - size.width - PopoverTuning.screenMargin
        if maxX >= minX { x = min(max(x, minX), maxX) }

        // The notch tip sits on the menu bar's bottom edge. The status item
        // button is inset inside the bar, so its own minY would bury the arrow
        // behind the bar; the status window's minY is the bar's real edge.
        let barBottom = buttonWindow.frame.minY
        let top = (barBottom < buttonRect.minY && buttonRect.minY - barBottom < 40)
            ? barBottom
            : buttonRect.minY
        let frame = NSRect(x: x, y: top - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        updateNotch()
    }

    private func updateNotch() {
        guard let button = anchorButton, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        anchor.notchCenterX = buttonRect.midX - panel.frame.minX
    }

    // MARK: Dismissal

    private func installMonitors() {
        removeMonitors()

        // Clicks inside our own app. Anything that is not the panel and not the
        // status item closes the popover. This replaces the old resignKey
        // observer, which fired on clicks inside the panel and closed it.
        insideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isOpen else { return event }
            if event.window === self.panel { return event }
            if let button = self.anchorButton, let window = button.window, event.window === window {
                return event
            }
            self.close()
            return event
        }

        // Clicks in other apps. The status item's own frame is excluded: its
        // action owns the toggle, and closing here would race it.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isOpen else { return }
            let point = NSEvent.mouseLocation
            if self.panel.frame.contains(point) { return }
            if let button = self.anchorButton, let window = button.window {
                let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                if rect.contains(point) { return }
            }
            self.close()
        }

        // Esc.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            return event
        }

        // Another app taking focus.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, self.isOpen else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
            self.close()
        }
    }

    private var isOpen: Bool {
        phase == .open || phase == .opening
    }

    private func removeMonitors() {
        if let monitor = insideMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = outsideMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        insideMonitor = nil
        outsideMonitor = nil
        keyMonitor = nil
        activationObserver = nil
    }
}
