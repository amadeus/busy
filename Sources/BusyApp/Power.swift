import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import BusyCore

final class SleepPrevention {
    private var assertion: IOPMAssertionID = 0
    func start() throws {
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Busy is keeping this Mac awake" as CFString,
            &assertion
        )
        guard result == kIOReturnSuccess else {
            throw BusyError.message("macOS could not prevent idle sleep (\(result)).")
        }
    }
    func stop() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
    deinit { stop() }
}

final class BatteryMonitor {
    private var source: CFRunLoopSource?
    private var previouslyHadBattery = false
    var onChange: (() -> Void)?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    func read() -> BatteryState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            // If the power service is unavailable, conservatively stop rather than
            // silently losing the user's battery protection.
            return BatteryState(percent: nil, onBattery: true)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            previouslyHadBattery = true
            let onBattery = description[kIOPSPowerSourceStateKey] as? String != kIOPSACPowerValue
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let percent: Int?
            if let current, let maximum, maximum > 0, current >= 0 {
                percent = min(100, max(0, Int(floor(current / maximum * 100))))
            } else { percent = nil }
            return BatteryState(percent: percent, onBattery: onBattery)
        }
        return BatteryState(percent: nil, onBattery: previouslyHadBattery, hasBattery: previouslyHadBattery)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
