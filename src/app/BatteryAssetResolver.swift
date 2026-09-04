//
// BatteryAssetResolver.swift
// Native macOS Battery Menu Bar Companion App
//

import AppKit
import UniformTypeIdentifiers

struct BatteryAssetResolver {
    static let fallbackDir = "/Users/gefaass/Desktop/addon-modules/working/macos-ch.bypass #2/battery_icons_combined/standard/dark/2x"
    
    // Proportional dimensions: 28.8 x 16.1 pt (aspect ratio ~1.786)
    static let targetWidth: CGFloat = 28.8
    static let targetHeight: CGFloat = 16.1
    static let canvasHeight: CGFloat = 18.5
    static let yOffset: CGFloat = 0.2 // Shifted downward for perfect optical centering in 22pt status bar
    
    static func resolveIcon(percentage: Int, isCharging: Bool, isBypass: Bool, isLowPowerMode: Bool = false, isMissing: Bool = false) -> NSImage {
        let snapped = min(100, max(0, ((percentage + 5) / 10) * 10))
        let filename: String
        
        if isMissing {
            filename = "battery_missing@2x.png"
        } else if isBypass {
            // Plug icon is ONLY for bypass
            filename = "battery_plugged_\(snapped)@2x.png"
        } else if isCharging {
            // Bolt icon is ONLY for charging
            filename = "battery_charging_\(snapped)@2x.png"
        } else {
            // Idle is for disable charger option, idle, and unplugged battery
            filename = "battery_\(snapped)@2x.png"
        }
        
        var baseImage: NSImage? = nil
        
        // 1. Try bundle high-res supersampled resources first
        if let resPath = Bundle.main.resourcePath {
            let bundleIconPath = (resPath as NSString).appendingPathComponent("icons/\(filename)")
            if let img = NSImage(contentsOfFile: bundleIconPath) {
                baseImage = img
            }
        }
        
        // 2. Try external asset directory fallback
        if baseImage == nil {
            let fallbackPath = "\(fallbackDir)/\(filename)"
            if let img = NSImage(contentsOfFile: fallbackPath) {
                baseImage = img
            }
        }
        
        if let src = baseImage {
            let processed = isLowPowerMode ? applyLowPowerYellowTint(src) : src
            return adjustIconCanvas(processed)
        }
        
        // 3. System symbol fallback
        if let sysImg = NSImage(systemSymbolName: isCharging ? "battery.100percent.bolt" : "battery.100percent", accessibilityDescription: "Battery") {
            sysImg.size = NSSize(width: targetWidth, height: targetHeight)
            return sysImg
        }
        
        return NSImage()
    }
    
    private static func applyLowPowerYellowTint(_ source: NSImage) -> NSImage {
        guard let tiff = source.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return source
        }
        
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard let data = bitmap.bitmapData else { return source }
        
        // Apple Low Power Mode Yellow (#FFD60A)
        let yellowR: UInt8 = 255
        let yellowG: UInt8 = 214
        let yellowB: UInt8 = 10
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bitmap.bytesPerRow) + (x * 4)
                let r = Int(data[offset])
                let g = Int(data[offset + 1])
                let b = Int(data[offset + 2])
                let a = data[offset + 3]
                
                if a > 0 {
                    let maxVal = max(r, max(g, b))
                    let minVal = min(r, min(g, b))
                    if maxVal - minVal > 25 {
                        data[offset] = yellowR
                        data[offset + 1] = yellowG
                        data[offset + 2] = yellowB
                    }
                }
            }
        }
        
        let resultImage = NSImage(size: source.size)
        resultImage.addRepresentation(bitmap)
        return resultImage
    }
    
    private static func adjustIconCanvas(_ source: NSImage) -> NSImage {
        let canvas = NSImage(size: NSSize(width: targetWidth, height: canvasHeight), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            NSGraphicsContext.current?.shouldAntialias = true
            
            source.draw(
                in: NSRect(x: 0, y: yOffset, width: targetWidth, height: targetHeight),
                from: NSRect(origin: .zero, size: source.size),
                operation: .sourceOver,
                fraction: 1.0
            )
            return true
        }
        canvas.isTemplate = false
        return canvas
    }

    static func iconForApp(name: String) -> NSImage {
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(name) == true ||
            name.localizedCaseInsensitiveContains($0.localizedName ?? "") == true
        }), let icon = app.icon {
            return icon
        }
        
        if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal"), name == "Terminal" {
            return NSWorkspace.shared.icon(forFile: appUrl.path)
        }
        if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor"), name.contains("Activity") {
            return NSWorkspace.shared.icon(forFile: appUrl.path)
        }
        if #available(macOS 11.0, *) {
            return NSWorkspace.shared.icon(for: .application)
        } else {
            return NSWorkspace.shared.icon(forFileType: "app")
        }
    }
}
