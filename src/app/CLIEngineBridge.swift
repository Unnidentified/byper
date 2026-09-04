//
// CLIEngineBridge.swift
// Native macOS Battery Menu Bar Companion App
//

import Foundation

struct BypassStatus: Decodable {
    let percentage: Int?
    let acAttached: Bool?
    let isCharging: Bool?
    let holdActive: Bool?
    let inMemoryHoldActive: Bool?
    let chargeLimit: Int?
    let amperage_mA: Int?
    let voltage_mV: Int?
    let wattage_W: Double?
    let cycleCount: Int?
    let temperature_C: Double?
    let adapterWatts: Int?
    let adapterVoltage_mV: Int?
    let adapterCurrent_mA: Int?
    let adapterDesc: String?
    let pmuConfigured: Int?
    let notChargingReason: UInt32?
    let notChargingReasonDesc: String?
}

struct CLIEngineBridge {
    static let cliPaths = [
        "/usr/local/bin/byper",
        "/usr/local/bin/byp",
        "/usr/local/bin/chbypass",
        (Bundle.main.resourcePath ?? "") + "/byper",
        (Bundle.main.resourcePath ?? "") + "/chbypass"
    ]
    
    static var resolvedCliPath: String? {
        for path in cliPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    static var isHelperInstalled: Bool {
        guard let path = resolvedCliPath, path.hasPrefix("/usr/local/bin") else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
    
    @discardableResult
    static func installHelperWithAdminPrivileges() -> Bool {
        guard let bundledPath = Bundle.main.resourceURL?.appendingPathComponent("byper").path ?? Bundle.main.path(forResource: "byper", ofType: nil),
              FileManager.default.fileExists(atPath: bundledPath) else {
            return false
        }
        
        let script = """
        do shell script "mkdir -p /usr/local/bin && cp -f '\(bundledPath)' /usr/local/bin/byper && chown root:wheel /usr/local/bin/byper && chmod 4755 /usr/local/bin/byper && ln -sf /usr/local/bin/byper /usr/local/bin/byp && ln -sf /usr/local/bin/byper /usr/local/bin/chbypass" with administrator privileges with prompt "byper requires administrator privileges to enable direct AC charging bypass."
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if error == nil {
                return true
            }
        }
        return false
    }

    @discardableResult
    static func runCommand(_ args: [String], allowPrompt: Bool = true) -> (output: String, exitCode: Int32) {
        var binaryPath = resolvedCliPath
        if binaryPath == nil && allowPrompt {
            if installHelperWithAdminPrivileges() {
                binaryPath = resolvedCliPath
            }
        }
        
        guard let validBinary = binaryPath else {
            return ("CLI binary not found", -1)
        }
        
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: validBinary)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            let status = process.terminationStatus
            
            // If command failed with permission error and we haven't prompted yet, try installing helper
            if status != 0 && allowPrompt && !isHelperInstalled {
                if installHelperWithAdminPrivileges() {
                    return runCommand(args, allowPrompt: false)
                }
            }
            
            return (output.trimmingCharacters(in: .whitespacesAndNewlines), status)
        } catch {
            return (error.localizedDescription, -1)
        }
    }
    
    static func getStatus() -> BypassStatus? {
        let (output, exitCode) = runCommand(["json"])
        guard exitCode == 0, let data = output.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        return try? decoder.decode(BypassStatus.self, from: data)
    }
    
    @discardableResult
    static func enableHoldSync() -> (output: String, exitCode: Int32) {
        return runCommand(["on"])
    }
    
    @discardableResult
    static func disableHoldSync() -> (output: String, exitCode: Int32) {
        return runCommand(["off"])
    }
    
    @discardableResult
    static func disableChargerSync() -> (output: String, exitCode: Int32) {
        return runCommand(["disable"])
    }
    
    @discardableResult
    static func toggleBypassSync() -> (output: String, exitCode: Int32) {
        return runCommand(["t"])
    }
    
    @discardableResult
    static func setPowerModeSync(_ mode: BatteryMonitor.PowerMode) -> (output: String, exitCode: Int32) {
        switch mode {
        case .charging:
            return disableHoldSync()
        case .bypass:
            return enableHoldSync()
        }
    }
    
    @discardableResult
    static func exportSessionLog() -> (path: String?, success: Bool) {
        let (output, exitCode) = runCommand(["export"])
        if exitCode == 0, output.contains("written: ") {
            let path = output.components(separatedBy: "written: ").last?.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path, true)
        }
        return (nil, false)
    }
    
    @discardableResult
    static func setLowPowerModeSync(enabled: Bool) -> (output: String, exitCode: Int32) {
        return runCommand(["lpm", enabled ? "1" : "0"])
    }
    
    static func enableHold() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runCommand(["on"])
        }
    }
    
    static func disableHold() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runCommand(["off"])
        }
    }
    
    static func toggleBypass() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runCommand(["t"])
        }
    }
    
    static func setLowPowerMode(enabled: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runCommand(["lpm", enabled ? "1" : "0"])
        }
    }
    
    // Slow exponential moving average (EMA) curve for CPU monitoring
    private static var appCpuEma: [String: Double] = [:]
    
    static func fetchHighEnergyApps() -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid,%cpu,ucomm,comm", "-r"]
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            
            let lines = output.components(separatedBy: "\n")
            
            let systemExclusions: Set<String> = [
                "kernel_task", "WindowServer", "ps", "top", "launchd", "byp", "byper", "chbypass",
                "CustomBattery", "loginwindow", "dasd", "siriactionsd", "BackgroundShortcutRunner",
                "mds", "mdworker", "mds_stores", "distnoted", "fseventsd", "logd", "opendirectoryd",
                "coreaudiod", "bluetoothd", "trustd", "syspolicyd", "runningboardd", "powerd",
                "PowerUIAgent", "PerfPowerServices", "analyticsd", "syslogd", "tccd", "secd", "agy"
            ]
            
            var currentSamples: [String: Double] = [:]
            
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count >= 4, let cpu = Double(parts[1]) else { continue }
                
                let ucomm = String(parts[2])
                let fullPath = String(parts[3])
                
                if systemExclusions.contains(ucomm) { continue }
                if fullPath.hasPrefix("/System/") || fullPath.hasPrefix("/usr/") || fullPath.hasPrefix("/Library/") {
                    continue
                }
                
                var displayName = ucomm
                if fullPath.contains(".app/") {
                    let segments = fullPath.components(separatedBy: "/")
                    if let appBundle = segments.first(where: { $0.hasSuffix(".app") }) {
                        displayName = appBundle.replacingOccurrences(of: ".app", with: "")
                    }
                }
                
                if systemExclusions.contains(displayName) { continue }
                currentSamples[displayName] = max(currentSamples[displayName] ?? 0.0, cpu)
            }
            
            // Slow EMA smoothing curve (alpha = 0.15) to prevent jumpy fluctuations
            let alpha = 0.15
            for (app, sample) in currentSamples {
                let prev = appCpuEma[app] ?? sample
                appCpuEma[app] = (alpha * sample) + ((1.0 - alpha) * prev)
            }
            for (app, prev) in appCpuEma where currentSamples[app] == nil {
                appCpuEma[app] = prev * 0.4
            }
            
            // Filter apps with smoothed CPU >= 18% and strictly limit to 2 apps
            let sorted = appCpuEma
                .filter { $0.value >= 18.0 }
                .sorted { $0.value > $1.value }
                .map { $0.key }
            
            return Array(sorted.prefix(2))
        } catch {
            return []
        }
    }
}
