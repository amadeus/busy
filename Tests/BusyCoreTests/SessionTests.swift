import XCTest
@testable import BusyCore

final class SessionTests: XCTestCase {
    func testFreshSessionIsUnlimitedAndCutoffDefaultsToTwenty() {
        let session = BusySession()
        XCTAssertNil(session.durationSeconds)
        XCTAssertNil(session.remaining(at: 100))
        XCTAssertEqual(session.batteryCutoff, 20)
    }

    func testStatusPreservesCountdownAndNewDurationRestartsIt() throws {
        var session = BusySession()
        try session.apply(BusyRequest(action: .update, durationSeconds: 120), now: 10)
        try session.apply(BusyRequest(action: .status), now: 40)
        XCTAssertEqual(session.remaining(at: 40), 90)
        try session.apply(BusyRequest(action: .update, batteryCutoff: 30), now: 50)
        XCTAssertEqual(session.remaining(at: 50), 80)
        try session.apply(BusyRequest(action: .update, durationSeconds: 60), now: 60)
        XCTAssertEqual(session.remaining(at: 60), 60)
        try session.apply(BusyRequest(action: .update, clearDuration: true), now: 70)
        XCTAssertNil(session.remaining(at: 70))
        XCTAssertEqual(session.batteryCutoff, 30)
    }

    func testBatteryOverridesSimultaneousDurationExpiry() throws {
        var session = BusySession()
        try session.apply(BusyRequest(action: .update, durationSeconds: 10), now: 0)
        XCTAssertEqual(session.endReason(battery: BatteryState(percent: 20, onBattery: true), now: 10), .batteryCutoff)
        XCTAssertEqual(session.endReason(battery: BatteryState(percent: 21, onBattery: true), now: 10), .durationElapsed)
    }

    func testPluggedInBelowCutoffRemainsActiveButUnpluggingEndsSession() {
        let session = BusySession()
        XCTAssertNil(session.endReason(battery: BatteryState(percent: 10, onBattery: false), now: 0))
        XCTAssertEqual(session.endReason(battery: BatteryState(percent: 10, onBattery: true), now: 0), .batteryCutoff)
    }

    func testMissingBatteryReadingFailsClosedOnlyOnBattery() {
        let session = BusySession()
        XCTAssertEqual(session.endReason(battery: BatteryState(percent: nil, onBattery: true), now: 0), .batteryUnavailable)
        XCTAssertNil(session.endReason(battery: BatteryState(percent: nil, onBattery: false, hasBattery: false), now: 0))
        XCTAssertNil(session.endReason(battery: BatteryState(percent: nil, onBattery: false), now: 0))
    }

    func testInvalidUpdateDoesNotPartiallyChangeSession() throws {
        var session = BusySession()
        try session.apply(BusyRequest(action: .update, durationSeconds: 100), now: 0)
        XCTAssertThrowsError(try session.apply(BusyRequest(action: .update, durationSeconds: -1, batteryCutoff: 50), now: 20))
        XCTAssertEqual(session.batteryCutoff, 20)
        XCTAssertEqual(session.remaining(at: 20), 80)
        for cutoff in [0, 101] {
            XCTAssertThrowsError(try BusyRequest(action: .update, batteryCutoff: cutoff).validate())
        }
        XCTAssertThrowsError(try BusyRequest(action: .update, durationSeconds: .infinity).validate())
        XCTAssertThrowsError(try BusyRequest(action: .update, durationSeconds: 1, clearDuration: true).validate())
        XCTAssertThrowsError(try BusyRequest(action: .status, batteryCutoff: 30).validate())
    }

    func testDuplicateStartupRequestDoesNotRestartCountdown() throws {
        var session = BusySession()
        let request = BusyRequest(action: .update, durationSeconds: 120)
        try session.apply(request, now: 0)
        try session.apply(request, now: 30)
        XCTAssertEqual(session.remaining(at: 30), 90)
        try session.apply(BusyRequest(action: .update, durationSeconds: 120), now: 40)
        XCTAssertEqual(session.remaining(at: 40), 120)
    }

    func testProtocolRoundTrip() throws {
        let request = BusyRequest(action: .update, durationSeconds: 7200, batteryCutoff: 25)
        XCTAssertEqual(try JSONDecoder().decode(BusyRequest.self, from: JSONEncoder().encode(request)), request)
    }
}
