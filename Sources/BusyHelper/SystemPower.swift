import Foundation
import Darwin
import IOKit.ps
import BusyCore

final class SystemPower: HelperPowerControl {
    func sleepDisabled() throws -> Bool {
        let output = try pmset(["-g"])
        guard output.contains("System-wide power settings:") else {
            throw BusyError.message("Cannot read system sleep settings.")
        }
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.first == "SleepDisabled" {
                guard fields.count == 2, fields[1] == "0" || fields[1] == "1" else {
                    throw BusyError.message("Unexpected system sleep setting.")
                }
                return fields[1] == "1"
            }
        }
        // An absent preference has the same effective behavior as zero.
        return false
    }
    func setSleepDisabled(_ disabled: Bool) throws {
        _ = try pmset(["disablesleep", disabled ? "1" : "0"])
    }
    private func pmset(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 3) != .success {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 1)
            throw BusyError.message("System power command timed out.")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, data.count < 65_536 else {
            throw BusyError.message("System power command failed.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private var hasObservedBattery = false

func readBattery() -> BatteryState {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
        return BatteryState(percent: nil, onBattery: true)
    }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
            return BatteryState(percent: nil, onBattery: true)
        }
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
        hasObservedBattery = true
        let onBattery = description[kIOPSPowerSourceStateKey] as? String != kIOPSACPowerValue
        guard let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
              current.isFinite, maximum.isFinite, maximum > 0, current >= 0, current <= maximum else {
            return BatteryState(percent: nil, onBattery: onBattery)
        }
        return BatteryState(percent: Int(floor(current / maximum * 100)), onBattery: onBattery)
    }
    if hasObservedBattery { return BatteryState(percent: nil, onBattery: true) }
    return BatteryState(percent: nil, onBattery: false, hasBattery: false)
}
