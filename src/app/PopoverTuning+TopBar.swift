//
// PopoverTuning+TopBar.swift
// Tuning for the TopBar region of the popover shell.
//
// Kept in its own file so the region can be worked on without touching the
// shared PopoverTuning block in GlassPopover.swift.
//

import SwiftUI

extension PopoverTuning {
    // MARK: - Top margin

    // Distance from the shell body's top edge to the top of the progress line.
    // The shell already pads the content by contentPadding, and the line sits
    // centred in a row as tall as the percentage text, so the row's own top is
    // topBarLineOffset above the line. Pulling the row up by the difference
    // lands the line here and shrinks the column by the same amount, so the gap
    // down to the card and the rail does not move.
    static let topBarTopInset: CGFloat = 8
    // Measured: the 4 pt line sat 4 pt below the row's top, because the row is
    // as tall as the 10.5 pt percentage text.
    static let topBarLineOffset: CGFloat = 4
    static var topBarPullUp: CGFloat {
        contentPadding + topBarLineOffset - topBarTopInset
    }

    // Extra inset on the row's trailing edge. The top-right corner is nearly
    // square now, so the power icon needs more air than the card's right edge
    // gives it: the glyph's ink lands topBarTrailingInset points further in,
    // which puts it 14 pt clear of the shell's right edge.
    static let topBarTrailingInset: CGFloat = 2

    // MARK: - Progress line tail

    // The line's left end used to stop as a blunt capsule cap. It now fades out
    // over its first tailLength points, and the front that carries the fade
    // curves down toward the rail's top-left shoulder.
    enum TailStyle {
        case curvedTail
        case slopedFade
    }

    static let tailStyle: TailStyle = .curvedTail

    // Horizontal extent of the tail, measured from the line's left end.
    static let tailLength: CGFloat = 26
    // How far the curved front drops from the right end of the tail to the left
    // end. The line is 4 pt tall, so this is the whole band: the front crosses
    // the line from its bottom edge up to its top edge.
    static let tailDrop: CGFloat = 4
    // Length over which the opacity ramps from zero to full, measured
    // horizontally. Two points short of tailLength so the arc has already
    // reached the top edge by the time the line is fully opaque.
    static let tailFadeLength: CGFloat = 24
    // The sloped style's front is a straight diagonal at this angle from the
    // horizontal.
    static let tailSlopeDegrees: CGFloat = 30
}

// The progress line's left end. Both styles ramp the opacity from zero at the
// left end to full at tailFadeLength, so the end dissolves instead of stopping
// as a blunt capsule cap. The curved style also cuts the band along the arc, so
// the line grows out of the rail's shoulder instead of a straight edge.
struct ProgressTailMask: View {
    var body: some View {
        GeometryReader { geo in
            switch PopoverTuning.tailStyle {
            case .curvedTail:
                TailArc()
                    .fill(horizontalRamp(width: geo.size.width))
            case .slopedFade:
                Rectangle()
                    .fill(slopedRamp(size: geo.size))
            }
        }
    }

    private func horizontalRamp(width: CGFloat) -> LinearGradient {
        let w = max(1, width)
        let fade = min(PopoverTuning.tailFadeLength, w)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: fade / w),
                .init(color: .white, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func slopedRamp(size: CGSize) -> LinearGradient {
        let w = max(1, size.width)
        let h = max(1, size.height)
        let angle = Double(PopoverTuning.tailSlopeDegrees) * .pi / 180
        let sinA = CGFloat(sin(angle))
        let cosA = CGFloat(cos(angle))
        // The front is a straight diagonal at tailSlopeDegrees from the
        // horizontal, so the ramp runs perpendicular to it, up and to the right.
        // Its length is set so the fade still spans tailFadeLength horizontally
        // along the line's bottom edge.
        let ramp = PopoverTuning.tailFadeLength * max(0.01, sinA)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 1),
            ],
            startPoint: UnitPoint(x: 0, y: 1),
            endPoint: UnitPoint(x: sinA * ramp / w, y: 1 - cosA * ramp / h)
        )
    }
}

// The region of the line that survives the tail: below a circular front that
// runs from the line's bottom edge at the left end up to its top edge at
// tailLength. The front's centre sits directly below the tail's right end, so
// it leaves the line horizontally there, the way the rail's shoulder leaves its
// top edge. A front concentric with the rail's corner itself would only span
// about 14 pt of a 4 pt line, short of the tail the user asked for.
private struct TailArc: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(PopoverTuning.tailLength, rect.width)
        let drop = min(PopoverTuning.tailDrop, rect.height)
        guard drop > 0, length > 0 else { return Path(rect) }
        // Radius through both ends of the front, with the centre on the
        // vertical through the right end.
        let r = (length * length + drop * drop) / (2 * drop)
        let centre = CGPoint(x: length, y: r)
        let start = Angle(radians: atan2(Double(drop - r), Double(-length)))
        var path = Path()
        path.move(to: CGPoint(x: 0, y: drop))
        path.addArc(center: centre, radius: r,
                    startAngle: start, endAngle: Angle(radians: -.pi / 2),
                    clockwise: false)
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}
