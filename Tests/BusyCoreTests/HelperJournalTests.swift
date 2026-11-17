import XCTest
import Darwin
@testable import BusyCore

final class HelperJournalTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("busy-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func journal() -> HelperFileJournal { HelperFileJournal(directory: directory.path, expectedOwner: getuid()) }

    func testDurablePrepareSurvivesNewInstanceAndClearRemovesIt() throws {
        XCTAssertFalse(try journal().isPending())
        try journal().prepare()
        XCTAssertTrue(try journal().isPending())
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("journal.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try journal().clear()
        XCTAssertFalse(try journal().isPending())
    }
    func testExistingJournalCannotBeReplaced() throws {
        try journal().prepare()
        XCTAssertThrowsError(try journal().prepare())
        XCTAssertTrue(try journal().isPending())
    }
    func testCorruptedJournalIsNotSilentlyDiscarded() throws {
        let path = directory.appendingPathComponent("journal.json")
        try Data("partial".utf8).write(to: path)
        XCTAssertThrowsError(try journal().isPending())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
    func testJournalSymlinkIsRejected() throws {
        let target = directory.appendingPathComponent("other")
        try Data("protected".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("journal.json"), withDestinationURL: target)
        XCTAssertThrowsError(try journal().isPending())
        XCTAssertThrowsError(try journal().prepare())
        XCTAssertEqual(try Data(contentsOf: target), Data("protected".utf8))
    }
    func testInsecurePermissionsAreRejected() throws {
        try journal().prepare()
        XCTAssertEqual(chmod(directory.appendingPathComponent("journal.json").path, 0o666), 0)
        XCTAssertThrowsError(try journal().isPending())
    }
}
