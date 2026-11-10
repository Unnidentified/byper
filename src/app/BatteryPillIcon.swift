//
// BatteryPillIcon.swift
// Native macOS Battery Menu Bar Companion App
//

import AppKit
import CoreText

/// Menu bar battery icon: a rounded pill whose fill tracks the charge level,
/// a detached D-shaped terminal nub, and the level punched out of the pill.
///
/// Everything is drawn in a 30 x 14 design space (body 27 x 14) that matches
/// the system battery, so the two sit at the same size in the menu bar. The
/// number is a hole rather than a drawn colour, which keeps the icon
/// monochrome: one ink at two opacities, the way a template image reads.
enum BatteryPillIcon {
    /// What the pill reports. Declaration order is precedence: the first
    /// matching case wins, so charging outranks bypass outranks low power.
    enum State {
        case charging
        case bypass
        case lowPower
        case idle
    }

    private static let designWidth: CGFloat = 30
    private static let designHeight: CGFloat = 14
    private static let bodyWidth: CGFloat = 27
    private static let cornerRadius: CGFloat = 4.2
    private static let trackOpacity: CGFloat = 0.44
    private static let nubOpacity: CGFloat = 0.55

    /// Digit ink height, measured off the system battery at 2x.
    private static let digitHeight: CGFloat = 8.8
    /// The number never takes more than this share of the body, so three
    /// digits shrink instead of running into the rounded ends.
    private static let maxDigitWidthRatio: CGFloat = 0.8

    // The base fill is black at 93% rather than a flat hex, so it picks up the
    // wallpaper tint through the menu bar material the way the system icon
    // does. The state colours are the ones the popover already uses.
    private static let ink = NSColor.black.withAlphaComponent(0.93)
    private static let paper = NSColor.white.withAlphaComponent(0.93)
    private static let chargingGreen = NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)
    private static let bypassCopper = NSColor(srgbRed: 0xDC / 255, green: 0x80 / 255, blue: 0x38 / 255, alpha: 1)
    private static let lowPowerGold = NSColor(srgbRed: 0xFF / 255, green: 0xD6 / 255, blue: 0x0A / 255, alpha: 1)
    private static let lowBatteryRed = NSColor(srgbRed: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)

    /// Height 12 matches the system battery pill in the menu bar. The design
    /// space is 30 x 14, so the default scale is 12/14.
    ///
    /// The menu bar brightness is read from the appearance the drawing handler
    /// runs under, not from a parameter: the bar follows the wallpaper, and
    /// that appearance is the only place the value is exposed. AppKit calls
    /// the handler once per candidate appearance and the last pass is the one
    /// on screen, so the icon always lands on the current bar.
    static func image(level: Int, state: State, height: CGFloat = 12) -> NSImage {
        let clamped = min(100, max(0, level))
        let scale = height / designHeight
        let size = NSSize(width: designWidth * scale, height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let isDarkMenuBar = NSAppearance.currentDrawing()
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ctx.saveGState()
            ctx.scaleBy(x: rect.width / designWidth, y: rect.height / designHeight)
            ctx.setShouldAntialias(true)
            draw(clamped, state: state, darkMenuBar: isDarkMenuBar, in: ctx)
            ctx.restoreGState()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ level: Int, state: State, darkMenuBar: Bool, in ctx: CGContext) {
        let base = darkMenuBar ? paper : ink

        let fill: NSColor
        let isColoured: Bool
        switch state {
        case .charging:
            fill = chargingGreen
            isColoured = true
        case .bypass:
            fill = bypassCopper
            isColoured = true
        case .lowPower:
            fill = lowPowerGold
            isColoured = true
        case .idle:
            if level <= 20 {
                fill = lowBatteryRed
                isColoured = true
            } else {
                fill = base
                isColoured = false
            }
        }

        let body = CGRect(x: 0, y: 0, width: bodyWidth, height: designHeight)
        let bodyPath = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // The system battery steps its fill in whole units instead of moving
        // linearly: at 41, 42 and 43 percent the edge sits on the same pixel.
        let chargeWidth = (bodyWidth * CGFloat(level) / 100).rounded()

        // Track and charge share one clip so the fill keeps the rounded left
        // edge at low levels instead of squaring off.
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        ctx.setFillColor(fill.withAlphaComponent(trackOpacity).cgColor)
        ctx.fill(body)
        if chargeWidth > 0 {
            ctx.setFillColor(fill.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: chargeWidth, height: designHeight))
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setFillColor(fill.withAlphaComponent(nubOpacity).cgColor)
        ctx.addPath(nubPath())
        ctx.fillPath()
        ctx.restoreGState()

        // A coloured pill is bright, so on a light menu bar the punched-out
        // number would show the light bar through the fill and wash out. Draw
        // it in the icon's own ink there instead, which keeps the number
        // monochrome with the rest of the pill and still reads on the fill.
        // On a dark menu bar the knockout already reads as dark digits, and
        // the idle pill is always the opposite of the bar, so both keep the
        // hole.
        let digitColor: NSColor? = (isColoured && !darkMenuBar) ? ink : nil
        drawNumber(level, in: ctx, body: bodyPath, color: digitColor)
    }

    /// Terminal nub: a D shape 1.6 wide and 4.7 tall, flat on the left, right
    /// corners rounded to r0.8. It sits 1.3 clear of the body.
    private static func nubPath() -> CGPath {
        let left: CGFloat = bodyWidth + 1.3
        let right: CGFloat = left + 1.6
        let bottom: CGFloat = 4.65
        let top: CGFloat = 9.35
        let radius: CGFloat = 0.8

        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addArc(center: CGPoint(x: right - radius, y: bottom + radius), radius: radius,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        path.addLine(to: CGPoint(x: right, y: top - radius))
        path.addArc(center: CGPoint(x: right - radius, y: top - radius), radius: radius,
                    startAngle: 0, endAngle: .pi / 2, clockwise: false)
        path.addLine(to: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }

    /// Draws the level. A nil colour punches it out of the pill so the menu
    /// bar shows through; a colour draws it on top of the fill.
    private static func drawNumber(_ level: Int, in ctx: CGContext, body: CGPath, color: NSColor?) {
        let text = "\(level)"
        let font = numberFont(for: text)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color ?? NSColor.black
        ])
        let line = CTLineCreateWithAttributedString(attributed)

        // Centre the ink, not the line box. Digits have no descender, so the
        // line box centre sits below the visual centre and the number reads
        // low in the pill.
        let inkBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard inkBounds.width > 0, inkBounds.height > 0 else { return }

        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.setBlendMode(color == nil ? .destinationOut : .normal)
        ctx.textPosition = CGPoint(
            x: bodyWidth / 2 - inkBounds.midX,
            y: designHeight / 2 - inkBounds.midY
        )
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// SF Pro at regular weight with proportional figures, which is what the
    /// system battery uses: its "1" is narrower than its "4", so "41" comes out
    /// narrower than "44". The size is derived from the font's own cap height
    /// so the digit ink lands on `digitHeight`, then trimmed if three digits
    /// would run wider than the body allows.
    private static func numberFont(for text: String) -> NSFont {
        let probeSize: CGFloat = 100
        let probe = NSFont.systemFont(ofSize: probeSize, weight: .regular)
        let capRatio = probe.capHeight / probeSize
        var size = digitHeight / capRatio

        let maxWidth = bodyWidth * maxDigitWidthRatio
        let width = inkWidth(of: text, font: NSFont.systemFont(ofSize: size, weight: .regular))
        if width > maxWidth {
            size *= maxWidth / width
        }
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }

    private static func inkWidth(of text: String, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width
    }
}
