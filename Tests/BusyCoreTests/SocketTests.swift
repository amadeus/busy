import XCTest
import Darwin
@testable import BusyCore

final class SocketTests: XCTestCase {
    private func pair() throws -> (Int32, Int32) {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw XCTSkip("Anonymous socketpair unavailable: \(String(cString: strerror(errno)))")
        }
        configureSocket(sockets[0])
        configureSocket(sockets[1])
        return (sockets[0], sockets[1])
    }

    func testRequestUsesNewlineFramingAndRoundTrips() throws {
        let (reader, writer) = try pair()
        defer { close(reader); close(writer) }
        let request = BusyRequest(action: .update, durationSeconds: 60, batteryCutoff: 25)
        try writeMessage(request, to: writer)
        let decoded = try JSONDecoder().decode(BusyRequest.self, from: readMessage(reader))
        XCTAssertEqual(decoded, request)
    }

    func testMalformedJSONIsRejectedAfterFraming() throws {
        let (reader, writer) = try pair()
        defer { close(reader); close(writer) }
        let data = Data("{bad json}\n".utf8)
        _ = data.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
        let message = try readMessage(reader)
        XCTAssertThrowsError(try JSONDecoder().decode(BusyRequest.self, from: message))
    }

    func testOversizedMessageIsRejected() throws {
        let (reader, writer) = try pair()
        defer { close(reader); close(writer) }
        let finished = expectation(description: "large writer finished")
        DispatchQueue.global().async {
            let data = Data(repeating: 65, count: 17_000)
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(writer, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count <= 0 { break }
                    offset += count
                }
            }
            finished.fulfill()
        }
        XCTAssertThrowsError(try readMessage(reader)) { error in
            XCTAssertEqual(error.localizedDescription, "Control message is too large.")
        }
        wait(for: [finished], timeout: 3)
    }

    func testSlowTrickleCannotExtendTotalReadDeadline() throws {
        let (reader, writer) = try pair()
        defer { close(reader); close(writer) }
        let finished = expectation(description: "writer finished")
        DispatchQueue.global().async {
            for _ in 0..<10 {
                var byte: UInt8 = 65
                _ = write(writer, &byte, 1)
                Thread.sleep(forTimeInterval: 0.3)
            }
            finished.fulfill()
        }
        let start = BusyTime.now
        XCTAssertThrowsError(try readMessage(reader)) { error in
            XCTAssertEqual(error.localizedDescription, "Timed out reading control message.")
        }
        XCTAssertLessThan(BusyTime.now - start, 2.8)
        wait(for: [finished], timeout: 5)
    }
}
