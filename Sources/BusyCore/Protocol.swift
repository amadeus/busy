import Foundation

public struct BusyRequest: Codable, Equatable {
    public enum Action: String, Codable { case status, update, stop }
    public var id: UUID
    public var action: Action
    public var durationSeconds: Double?
    public var clearDuration: Bool
    public var batteryCutoff: Int?

    public init(id: UUID = UUID(), action: Action, durationSeconds: Double? = nil, clearDuration: Bool = false, batteryCutoff: Int? = nil) {
        self.id = id
        self.action = action
        self.durationSeconds = durationSeconds
        self.clearDuration = clearDuration
        self.batteryCutoff = batteryCutoff
    }

    public func validate() throws {
        if action != .update && (durationSeconds != nil || clearDuration || batteryCutoff != nil) {
            throw BusyError.message("Only update requests may change settings.")
        }
        if let seconds = durationSeconds, !seconds.isFinite || seconds <= 0 || seconds > 31_536_000 {
            throw BusyError.message("Duration must be greater than zero and no longer than one year.")
        }
        if clearDuration && durationSeconds != nil {
            throw BusyError.message("Choose either a duration or unlimited.")
        }
        if let cutoff = batteryCutoff, !(1...100).contains(cutoff) {
            throw BusyError.message("Battery cutoff must be between 1 and 100 percent.")
        }
    }
}

public struct BusyStatus: Codable, Equatable {
    public var active: Bool
    public var durationSeconds: Double?
    public var remainingSeconds: Double?
    public var batteryPercent: Int?
    public var onBattery: Bool
    public var batteryCutoff: Int
    public var closedLidSupported: Bool

    public init(active: Bool, durationSeconds: Double?, remainingSeconds: Double?, batteryPercent: Int?, onBattery: Bool, batteryCutoff: Int, closedLidSupported: Bool) {
        self.active = active
        self.durationSeconds = durationSeconds
        self.remainingSeconds = remainingSeconds
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        self.batteryCutoff = batteryCutoff
        self.closedLidSupported = closedLidSupported
    }
}

public struct BusyResponse: Codable, Equatable {
    public var status: BusyStatus?
    public var error: String?
    public init(status: BusyStatus? = nil, error: String? = nil) {
        self.status = status
        self.error = error
    }
}

public enum BusyError: LocalizedError {
    case message(String)
    case notRunning
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .notRunning: return "Busy is not running."
        }
    }
}
