import XCTest
@testable import BusyCore

final class HelperLeaseTests: XCTestCase {
    final class Power: HelperPowerControl {
        var disabled = false
        var failRestore = false
        var changes: [Bool] = []
        func sleepDisabled() throws -> Bool { disabled }
        func setSleepDisabled(_ value: Bool) throws {
            if !value && failRestore { throw BusyError.message("restore failed") }
            changes.append(value)
            disabled = value
        }
    }
    final class Journal: HelperRecoveryJournal {
        var pending = false
        var failPrepare = false
        func isPending() throws -> Bool { pending }
        func prepare() throws {
            if failPrepare { throw BusyError.message("disk full") }
            pending = true
        }
        func clear() throws { pending = false }
    }
    let token = UUID().uuidString
    let healthy = BatteryState(percent: 80, onBattery: true)

    func testCrashRecoveryRestoresBeforeNextSession() throws {
        let power = Power(), journal = Journal()
        var lease = HelperLease(power: power, journal: journal)
        try lease.acquire(token: token, cutoff: 20, battery: healthy, now: 0)
        XCTAssertTrue(power.disabled)
        XCTAssertTrue(journal.pending)
        lease = HelperLease(power: power, journal: journal)
        try lease.recover()
        XCTAssertFalse(power.disabled)
        XCTAssertFalse(journal.pending)
    }
    func testExpiryCannotBeRevivedByLateHeartbeat() throws {
        let power = Power(), journal = Journal()
        let lease = HelperLease(power: power, journal: journal)
        try lease.acquire(token: token, cutoff: 20, battery: healthy, now: 0)
        XCTAssertThrowsError(try lease.renew(token: token, cutoff: 20, battery: healthy, now: 12))
        XCTAssertFalse(power.disabled)
        XCTAssertFalse(journal.pending)
    }
    func testBatteryCutoffWinsEvenWithFreshHeartbeat() throws {
        let power = Power(), journal = Journal()
        let lease = HelperLease(power: power, journal: journal)
        try lease.acquire(token: token, cutoff: 20, battery: healthy, now: 0)
        XCTAssertThrowsError(try lease.renew(token: token, cutoff: 20, battery: BatteryState(percent: 20, onBattery: true), now: 1))
        XCTAssertFalse(power.disabled)
    }
    func testCutoffUpdateAppliesImmediately() throws {
        let power = Power(), journal = Journal()
        let lease = HelperLease(power: power, journal: journal)
        try lease.acquire(token: token, cutoff: 20, battery: healthy, now: 0)
        XCTAssertThrowsError(try lease.renew(token: token, cutoff: 80, battery: healthy, now: 1))
        XCTAssertFalse(power.disabled)
    }
    func testMissingBatteryFailsClosedAndACBelowCutoffIsAllowed() throws {
        let power = Power(), journal = Journal()
        let lease = HelperLease(power: power, journal: journal)
        try lease.acquire(token: token, cutoff: 20, battery: BatteryState(percent: 10, onBattery: false), now: 0)
        XCTAssertThrowsError(try lease.tick(battery: BatteryState(percent: nil, onBattery: false), now: 1))
        XCTAssertFalse(power.disabled)
    }
    func testPreexistingDisabledSleepIsNeverChanged() {
        let power = Power(), journal = Journal()
        power.disabled = true
        let lease = HelperLease(power: power, journal: journal)
        XCTAssertThrowsError(try lease.acquire(token: token, cutoff: 20, battery: healthy, now: 0))
        XCTAssertTrue(power.disabled)
        XCTAssertTrue(power.changes.isEmpty)
        XCTAssertFalse(journal.pending)
    }
    func testOutsideEnableIsRespectedAndLeaseEnds() throws {
        let power = Power(), journal = Journal()
        let lease = HelperLease(power: power, journal: journal)
        try lease.acquire(token: token, cutoff: 20, battery: healthy, now: 0)
        power.disabled = false
        try lease.tick(battery: healthy, now: 1)
        XCTAssertThrowsError(try lease.renew(token: token, cutoff: 20, battery: healthy, now: 2))
        XCTAssertEqual(power.changes, [true])
    }
    func testFailedRestorationRetainsJournalAndRetries() throws {
        let power = Power(), journal = Journal()
        let lease = HelperLease(power: power, journal: journal)
        try lease.acquire(token: token, cutoff: 20, battery: healthy, now: 0)
        power.failRestore = true
        XCTAssertThrowsError(try lease.release(token: token))
        XCTAssertTrue(journal.pending)
        XCTAssertTrue(power.disabled)
        power.failRestore = false
        try lease.tick(battery: healthy, now: 2)
        XCTAssertFalse(journal.pending)
        XCTAssertFalse(power.disabled)
    }
    func testJournalFailureDoesNotChangePowerSetting() {
        let power = Power(), journal = Journal()
        journal.failPrepare = true
        let lease = HelperLease(power: power, journal: journal)
        XCTAssertThrowsError(try lease.acquire(token: token, cutoff: 20, battery: healthy, now: 0))
        XCTAssertTrue(power.changes.isEmpty)
    }
    func testWrongSessionCannotReleaseOrRenew() throws {
        let power = Power(), journal = Journal()
        let lease = HelperLease(power: power, journal: journal)
        try lease.acquire(token: token, cutoff: 20, battery: healthy, now: 0)
        let other = UUID().uuidString
        XCTAssertThrowsError(try lease.release(token: other))
        XCTAssertThrowsError(try lease.renew(token: other, cutoff: 20, battery: healthy, now: 1))
        XCTAssertTrue(power.disabled)
        try lease.release(token: token)
        XCTAssertFalse(power.disabled)
    }
}
