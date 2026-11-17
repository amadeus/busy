import Foundation

public struct BatteryState: Equatable {
    public var percent: Int?
    public var onBattery: Bool
    public var hasBattery: Bool
    public init(percent: Int?, onBattery: Bool, hasBattery: Bool = true) {
        self.percent = percent
        self.onBattery = onBattery
        self.hasBattery = hasBattery
    }
}

/// Time is supplied by the caller so countdowns can use a monotonic clock.
public struct BusySession {
    public enum EndReason: Equatable { case batteryCutoff, durationElapsed, batteryUnavailable }
    public private(set) var durationSeconds: Double?
    public private(set) var deadline: Double?
    public private(set) var batteryCutoff: Int
    private var appliedRequests: [UUID] = []

    public init(batteryCutoff: Int = 20) {
        self.batteryCutoff = (1...100).contains(batteryCutoff) ? batteryCutoff : 20
    }

    public mutating func apply(_ request: BusyRequest, now: Double) throws {
        try request.validate()
        guard request.action == .update, !appliedRequests.contains(request.id) else { return }
        appliedRequests.append(request.id)
        if appliedRequests.count > 64 { appliedRequests.removeFirst() }
        if let cutoff = request.batteryCutoff { batteryCutoff = cutoff }
        if request.clearDuration {
            durationSeconds = nil
            deadline = nil
        } else if let seconds = request.durationSeconds {
            durationSeconds = seconds
            deadline = now + seconds
        }
    }

    public func remaining(at now: Double) -> Double? {
        deadline.map { max(0, $0 - now) }
    }

    public func endReason(battery: BatteryState, now: Double) -> EndReason? {
        if battery.hasBattery && battery.onBattery {
            guard let percent = battery.percent else { return .batteryUnavailable }
            if percent <= batteryCutoff { return .batteryCutoff }
        }
        if let deadline, now >= deadline { return .durationElapsed }
        return nil
    }
}

public enum BusyTime {
    /// mach_continuous_time includes time spent asleep if macOS forces sleep.
    public static var now: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
