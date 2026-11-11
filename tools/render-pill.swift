// Dev tool, not part of the build. Renders BatteryPillIcon at a given scale so
// the menu bar icon can be compared against the system battery without taking a
// screenshot every round.
//
//   swiftc -O -o /tmp/render-pill tools/render-pill.swift src/app/BatteryPillIcon.swift
//   /tmp/render-pill out.png <level> <idle|charging|bypass|lowPower> <light|dark> [scale]
//
// The output is device pixels, so scale 2 gives the same raster the menu bar
// draws on a Retina display. The image is drawn through an NSBitmapImageRep
// whose point size is the icon's point size, so the drawing handler runs with
// the same 2x ctm the menu bar gives it. Rasterising through
// cgImage(forProposedRect:) instead renders at 1x and upscales, which blurs the
// glyphs and makes the digits measure a pixel wide.

import AppKit
import CoreGraphics
import Foundation

@main
struct RenderPill {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 5 else {
            FileHandle.standardError.write("usage: render-pill <out.png> <level> <state> <light|dark> [scale]\n".data(using: .utf8)!)
            exit(2)
        }

        let outPath = args[1]
        guard let level = Int(args[2]) else { exit(2) }

        let state: BatteryPillIcon.State
        switch args[3] {
        case "idle": state = .idle
        case "charging": state = .charging
        case "bypass": state = .bypass
        case "lowPower": state = .lowPower
        default: exit(2)
        }

        let appearanceName: NSAppearance.Name = (args[4] == "dark") ? .darkAqua : .aqua
        let scale: CGFloat = args.count > 5 ? (CGFloat(Double(args[5]) ?? 2)) : 2

        // The icon is 12 pt tall in the menu bar, in a 30 x 14 design space.
        let pointHeight: CGFloat = 12
        let pointWidth = pointHeight * 30.0 / 14.0
        let pxW = Int((pointWidth * scale).rounded())
        let pxH = Int((pointHeight * scale).rounded())

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { exit(1) }
        rep.size = NSSize(width: pointWidth, height: pointHeight)

        guard let appearance = NSAppearance(named: appearanceName) else { exit(1) }
        appearance.performAsCurrentDrawingAppearance {
            let img = BatteryPillIcon.image(level: level, state: state, height: pointHeight)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            img.draw(in: NSRect(x: 0, y: 0, width: pointWidth, height: pointHeight))
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try data.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath) \(pxW)x\(pxH) level=\(level) state=\(args[3]) bar=\(args[4]) scale=\(scale)")
    }
}
