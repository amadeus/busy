import XCTest
@testable import BusyCore

final class SettingsTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("busy-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testOnlyCutoffPersistsAcrossNewSessions() throws {
        let store = BusySettingsStore(directory: directory)
        XCTAssertEqual(store.loadBatteryCutoff(), 20)
        var session = BusySession(batteryCutoff: store.loadBatteryCutoff())
        try session.apply(BusyRequest(action: .update, durationSeconds: 3600, batteryCutoff: 35), now: 0)
        try store.saveBatteryCutoff(session.batteryCutoff)
        let restarted = BusySession(batteryCutoff: BusySettingsStore(directory: directory).loadBatteryCutoff())
        XCTAssertEqual(restarted.batteryCutoff, 35)
        XCTAssertNil(restarted.durationSeconds)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("settings.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInvalidSaveDoesNotOverwriteExistingCutoff() throws {
        let store = BusySettingsStore(directory: directory)
        try store.saveBatteryCutoff(25)
        XCTAssertThrowsError(try store.saveBatteryCutoff(0))
        XCTAssertEqual(store.loadBatteryCutoff(), 25)
    }

    func testCorruptAndOutOfRangeStoredValuesUseDefault() throws {
        let store = BusySettingsStore(directory: directory)
        let file = directory.appendingPathComponent("settings.json")
        for text in ["not json", "{\"batteryCutoff\":0}", "{\"batteryCutoff\":101}"] {
            try Data(text.utf8).write(to: file)
            XCTAssertEqual(store.loadBatteryCutoff(), 20)
        }
    }
}
