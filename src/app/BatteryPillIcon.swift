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
    /// Corner radius of the body, in design units. The system battery's corner
    /// measures 8.15 px at 2x, which is 4.075 pt, and one design unit is
    /// 12/14 pt, so 4.075 / (12/14) = 4.75 units. This single value drives all
    /// three places the body curve appears: the outline path, the clip that the
    /// track and the charge share, and the digit knockout clip. They all take
    /// the one path built from it in `draw`, so they cannot drift apart.
    private static let cornerRadius: CGFloat = 4.75
    /// Track alpha in the idle pill. The system battery's track measures
    /// 134.1 on a 233 bar, which is 0.425 of the bar, so the track is the same
    /// ink as the charge at a little under half strength. At 0.44 the track
    /// read 133.5 against the system's 136.8 on a 238 bar.
    private static let trackOpacity: CGFloat = 0.425
    /// Track alpha on a dark menu bar only. The system's dark track measures
    /// 0.450 of the bar, so the dark side needs its own value and the light
    /// bars keep 0.425. Read only when darkMenuBar is true.
    private static let darkTrackOpacity: CGFloat = 0.450
    private static let colouredTrackOpacity: CGFloat = 0.20
    private static let nubOpacity: CGFloat = 0.55

    /// How much of the pill the number removes. The system battery's knockout
    /// is not a full cut: its brightest hole measures 205 on a 238 bar and 161
    /// on a 187 bar, which is 0.85 of whatever sits underneath, so a little of
    /// the fill stays in the hole and the strokes read softer than a clean
    /// punch. A full cut measured 238 and 187, which is the bar itself.
    private static let knockoutAlpha: CGFloat = 0.85

    /// Digit ink height, measured off the system battery at 2x.
    private static let digitHeight: CGFloat = 8.4
    /// The status item draws the image one device pixel higher than the same
    /// image drawn into a bitmap context, so the baseline carries a one pixel
    /// offset to land where the system battery sits.
    private static let baselineNudgePx: CGFloat = 1
    /// The number never takes more than this share of the body, so three
    /// digits shrink instead of running into the rounded ends.
    private static let maxDigitWidthRatio: CGFloat = 0.8

    // The base fill is black at 91% rather than a flat hex, so it picks up the
    // wallpaper tint through the menu bar material the way the system icon
    // does. The state colours are the ones the popover already uses.
    //
    // 91 is measured, not guessed. The system battery's charged end sits at
    // 8.6% of the bar: 20.4 on a 238 bar and 16.0 on a 187 bar, which is an
    // ink alpha of 0.914. The icon used to read 9.3 and 7.3 because the track
    // was painted under the charge and the two alphas compounded; see the
    // track fill in `draw`.
    private static let ink = NSColor.black.withAlphaComponent(0.91)
    /// Ink alpha on a dark menu bar only. The system's dark ink measures 0.946
    /// of the bar, more opaque than the 0.91 the light bar needs, so the dark
    /// side carries its own value and the light bars do not move. Read only
    /// when darkMenuBar is true.
    private static let darkInkAlpha: CGFloat = 0.946
    private static let paper = NSColor.white.withAlphaComponent(darkInkAlpha)
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
            // Device pixels per point, read off the context rather than
            // assumed to be 2. The context is scaled to design units, so one
            // design unit is ctm.a device pixels and one point is
            // designHeight / height design units.
            let pxPerPoint = abs(ctx.ctm.a) * designHeight / height
            draw(clamped, state: state, darkMenuBar: isDarkMenuBar,
                 pxPerPoint: pxPerPoint, in: ctx)
            ctx.restoreGState()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ level: Int, state: State, darkMenuBar: Bool,
                             pxPerPoint: CGFloat, in ctx: CGContext) {
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
        // One path, one radius. The outline, the track and charge clip below,
        // and the digit knockout clip in drawNumber all use this same path, so
        // the three curves stay in sync by construction.
        let bodyPath = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // The system battery steps its fill instead of moving linearly: at 41,
        // 42 and 43 percent the edge sits on the same pixel. The step is one
        // point, not one design unit, so the edge is worked out in device
        // pixels and converted back to design units for the fill rect.
        let pxPerUnit = abs(ctx.ctm.a)
        let chargeWidth = chargeEdgePx(level: level,
                                       bodyWidthPx: bodyWidth * pxPerUnit,
                                       pxPerPoint: pxPerPoint) / pxPerUnit

        // Track and charge share one clip so the fill keeps the rounded left
        // edge at low levels instead of squaring off. The track is the menu
        // bar ink, not a tint of the mode colour: the system battery keeps a
        // neutral grey track behind a green or yellow charge. The coloured
        // states use a lighter track than the idle pill, which is what the
        // system battery does.
        //
        // The track is painted only where the charge is not. Painting it
        // across the whole body and then laying the charge on top compounds
        // the two alphas, and in the idle state both are translucent:
        // 1 - (1 - 0.44) x (1 - 0.93) = 0.96, which is darker than the system
        // battery's 0.91. Measured on a 238 bar the charged end read 9.3 with
        // the track underneath and 16.8 with it kept out, against the system's
        // 20.4, so the compounding was the whole of the error. The coloured
        // states fill opaquely and were never affected.
        let trackAlpha = isColoured ? colouredTrackOpacity
            : (darkMenuBar ? darkTrackOpacity : trackOpacity)
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        if chargeWidth > 0 {
            ctx.setFillColor(fill.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: chargeWidth, height: designHeight))
        }
        ctx.setFillColor(base.withAlphaComponent(trackAlpha).cgColor)
        ctx.fill(CGRect(x: chargeWidth, y: 0,
                        width: bodyWidth - chargeWidth, height: designHeight))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setFillColor(base.withAlphaComponent(nubOpacity).cgColor)
        ctx.addPath(nubPath())
        ctx.fillPath()
        ctx.restoreGState()

        // The system battery draws the number in the menu bar text colour, not
        // in the charge colour: black on a light bar, white on a dark one. The
        // idle pill is the exception, because there the pill itself is the ink
        // and the number is a hole.
        let digitColor: NSColor? = isColoured ? base : nil
        drawNumber(level, in: ctx, body: bodyPath, color: digitColor)
    }

    /// Where the charge ends, in device pixels, quantised the way the system
    /// battery quantises it.
    ///
    /// The system snaps the fill to the point grid, not to the pixel grid. At
    /// 2x that means every stock edge is even, and measured off the system
    /// battery the edge is 24 px at 50 percent, 30 at 65, 34 at 75 and 38 at
    /// 81. Those are round(level / 100 x 23.14 pt) x 2, where 23.14 pt is the
    /// body's width in points. Rounding in device pixels instead gives 23, 30,
    /// 35 and 37, which misses three of the four, and flooring gives 23, 29,
    /// 34 and 37, which misses three as well. The scale comes from the drawing
    /// context, so the same rule holds at 1x and 3x.
    ///
    /// This is the only place the rule lives. Change the rounding here and the
    /// whole icon follows.
    private static func chargeEdgePx(level: Int, bodyWidthPx: CGFloat,
                                     pxPerPoint: CGFloat) -> CGFloat {
        (bodyWidthPx * CGFloat(level) / 100 / pxPerPoint).rounded() * pxPerPoint
    }

    /// Terminal nub: a D shape, flat on the left, fully rounded on the right.
    /// The height, the left edge and the 1.3 unit gap to the body are the ones
    /// the icon already had; only the right side changed. A rounded rect with
    /// a small radius reads as a rectangle, and a plain ellipse is too wide at
    /// the top and bottom rows and too narrow in the middle, so the right side
    /// is a superellipse. Exponent 1.64 with a 0.071 unit flat shoulder is what
    /// the system battery's nub measures at 2x, cell for cell.
    private static func nubPath() -> CGPath {
        let left: CGFloat = bodyWidth + 1.3
        let bottom: CGFloat = 4.65
        let top: CGFloat = 9.35
        let width: CGFloat = 1.735
        let shoulder: CGFloat = 0.071
        let exponent: CGFloat = 1.64

        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: bottom))
        // Walk the right side from the bottom shoulder to the top one. The
        // curve is a superellipse, so it is sampled rather than built from
        // arcs; 48 steps is far finer than the 3 px the nub is wide at 2x.
        let steps = 48
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let d = abs(2 * t - 1)
            let s = CGFloat(pow(max(0, 1 - pow(Double(d), Double(exponent))),
                                1 / Double(exponent)))
            path.addLine(to: CGPoint(x: left + shoulder + (width - shoulder) * s,
                                     y: bottom + t * (top - bottom)))
        }
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
            .foregroundColor: color ?? NSColor.black.withAlphaComponent(knockoutAlpha)
        ])
        let line = CTLineCreateWithAttributedString(attributed)

        // Centre the ink, not the line box. Digits have no descender, so the
        // line box centre sits below the visual centre and the number reads
        // low in the pill.
        let inkBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard inkBounds.width > 0, inkBounds.height > 0 else { return }

        // CoreText snaps the glyph raster to the device pixel grid, so a
        // sub-pixel target lands on whichever side of the snap the context
        // happens to fall. Work in device pixels, read the scale from the ctm
        // rather than assuming 2, and put the baseline in the middle of a snap
        // step so the result does not depend on the context. The centre comes
        // from the font's cap height rather than the string's ink box, because
        // the ink box shifts with the digits and would move the baseline
        // between levels.
        let scaleY = abs(ctx.ctm.d)
        let targetBaselinePx = (designHeight / 2 - font.capHeight / 2) * scaleY + baselineNudgePx
        let baselinePx = targetBaselinePx.rounded(.up) - 0.5

        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        // The menu bar hands the drawing handler a context with font smoothing
        // on, which spreads a one pixel stem over its neighbours and drops the
        // peak coverage to about 86 percent. The system battery draws its
        // digits with plain antialiasing, so the holes read as solid. Turn
        // smoothing off so the raster matches the system glyphs.
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSubpixelPositionFonts(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setBlendMode(color == nil ? .destinationOut : .normal)
        ctx.textPosition = CGPoint(
            x: bodyWidth / 2 - inkBounds.midX,
            y: baselinePx / scaleY
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
