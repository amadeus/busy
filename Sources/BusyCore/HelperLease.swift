import Foundation

public protocol HelperPowerControl: AnyObject {
    func sleepDisabled() throws -> Bool
    func setSleepDisabled(_ disabled: Bool) throws
}

public protocol HelperRecoveryJournal: AnyObject {
    func isPending() throws -> Bool
    func prepare() throws
    func clear() throws
}

/// Owns only a transition from enabled sleep to disabled sleep. An existing
/// disabled setting belongs to someone else and cannot safely be borrowed.
public final class HelperLease {
    private let power: HelperPowerControl
    private let journal: HelperRecoveryJournal
    private let clock: (() -> Double)?
    private var token: String?
    private var deadline: Double = 0
    private var cutoff: Int = 20
    public static let lifetime: Double = 12

    public init(power: HelperPowerControl, journal: HelperRecoveryJournal, clock: (() -> Double)? = nil) {
        self.power = power
        self.journal = journal
        self.clock = clock
    }

    public func recover() throws {
        token = nil
        if try journal.isPending() {
            if try power.sleepDisabled() { try power.setSleepDisabled(false) }
            guard try !power.sleepDisabled() else { throw BusyError.message("Could not restore normal sleep.") }
            try journal.clear()
        }
    }

    public func acquire(token newToken: String, cutoff: Int, battery: BatteryState, now: Double) throws {
        try validate(token: newToken, cutoff: cutoff)
        try checkBattery(battery, cutoff: cutoff)
        guard token == nil else { throw BusyError.message("Closed-lid protection already has an active session.") }
        try recover()
        guard try !power.sleepDisabled() else {
            throw BusyError.message("System sleep is already disabled outside Busy. Restore normal sleep before starting closed-lid protection.")
        }
        try journal.prepare()
        do {
            try power.setSleepDisabled(true)
            guard try power.sleepDisabled() else { throw BusyError.message("macOS did not enable closed-lid protection.") }
        } catch {
            try? recover()
            throw error
        }
        token = newToken
        self.cutoff = cutoff
        deadline = (clock?() ?? now) + Self.lifetime
    }

    public func renew(token requestToken: String, cutoff: Int, battery: BatteryState, now: Double) throws {
        try validate(token: requestToken, cutoff: cutoff)
        try tick(battery: battery, now: now)
        guard token == requestToken else { throw BusyError.message("Closed-lid protection ended. Start a new Busy session.") }
        do { try checkBattery(battery, cutoff: cutoff) }
        catch { try recover(); throw error }
        self.cutoff = cutoff
        deadline = (clock?() ?? now) + Self.lifetime
    }

    public func release(token requestToken: String) throws {
        guard token == requestToken else {
            // An already-expired lease has nothing left to release.
            if token == nil { try recover(); return }
            throw BusyError.message("The closed-lid session does not match.")
        }
        try recover()
    }

    public func tick(battery: BatteryState, now: Double) throws {
        guard token != nil else {
            // Retry a restoration that failed on a previous tick.
            try recover()
            return
        }
        do {
            try checkBattery(battery, cutoff: cutoff)
            guard now < deadline else { try recover(); return }
            if try !power.sleepDisabled() {
                // Respect an outside request to allow sleep. Never reapply it.
                try recover()
            }
        } catch {
            try recover()
            throw error
        }
    }

    private func validate(token: String, cutoff: Int) throws {
        guard UUID(uuidString: token) != nil, (1...100).contains(cutoff) else {
            throw BusyError.message("Invalid closed-lid session request.")
        }
    }

    private func checkBattery(_ battery: BatteryState, cutoff: Int) throws {
        if battery.hasBattery {
            guard let percent = battery.percent, (0...100).contains(percent) else {
                throw BusyError.message("Battery level is unavailable; closed-lid protection stopped.")
            }
            if battery.onBattery && percent <= cutoff {
                throw BusyError.message("Battery cutoff reached; closed-lid protection stopped.")
            }
        }
    }
}
