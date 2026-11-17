import Foundation
import Darwin

public struct HelperRequest: Codable {
    public enum Action: String, Codable { case acquire, renew, release }
    public var action: Action
    public var token: String
    public var batteryCutoff: Int
    public init(action: Action, token: String, batteryCutoff: Int = 20) {
        self.action = action
        self.token = token
        self.batteryCutoff = batteryCutoff
    }
}

public struct HelperResponse: Codable {
    public var error: String?
    public init(error: String? = nil) { self.error = error }
}

public enum BusyHelperClient {
    public static let socketPath = "/var/run/com.amadeus.Busy/helper.sock"
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/com.amadeus.Busy.helper")
    }
    public static func acquire(token: String, batteryCutoff: Int) throws {
        try send(HelperRequest(action: .acquire, token: token, batteryCutoff: batteryCutoff))
    }
    public static func renew(token: String, batteryCutoff: Int) throws {
        try send(HelperRequest(action: .renew, token: token, batteryCutoff: batteryCutoff))
    }
    public static func release(token: String) throws {
        try send(HelperRequest(action: .release, token: token))
    }
    private static func send(_ request: HelperRequest) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("Create helper socket") }
        defer { close(fd) }
        configureSocket(fd)
        try withSocketAddress(socketPath) { address, size in
            guard connect(fd, address, size) == 0 else { throw socketError("Connect to Busy helper") }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else {
            throw BusyError.message("Busy helper is not running as administrator.")
        }
        try writeMessage(request, to: fd)
        let response = try JSONDecoder().decode(HelperResponse.self, from: helperReadMessage(fd, timeout: 15, limit: 4096))
        if let error = response.error { throw BusyError.message(error) }
    }
}

/// Client I/O runs away from the lease/watchdog queue. Each client gets a total
/// read deadline, so a slow stream cannot indefinitely hold server resources.
public final class HelperServer {
    private let queue = DispatchQueue(label: "app.busy.helper.accept")
    private let workers = DispatchQueue(label: "app.busy.helper.clients", attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 8)
    private var source: DispatchSourceRead?
    public init() {}
    public func start(authorizedUID: uid_t, handler: @escaping (HelperRequest) -> HelperResponse) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("Create helper socket") }
        do {
            configureSocket(fd)
            unlink(BusyHelperClient.socketPath)
            try withSocketAddress(BusyHelperClient.socketPath) { address, size in
                guard bind(fd, address, size) == 0 else { throw socketError("Bind helper socket") }
            }
            guard chown(BusyHelperClient.socketPath, authorizedUID, 0) == 0,
                  chmod(BusyHelperClient.socketPath, 0o600) == 0,
                  listen(fd, 8) == 0 else { throw socketError("Secure helper socket") }
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw socketError("Configure helper listener") }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [workers, slots] in
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                guard slots.wait(timeout: .now()) == .success else { close(client); return }
                workers.async {
                    defer { close(client); slots.signal() }
                    configureSocket(client)
                    var uid: uid_t = 0
                    var gid: gid_t = 0
                    guard getpeereid(client, &uid, &gid) == 0, uid == authorizedUID else { return }
                    do {
                        let data = try helperReadMessage(client, timeout: 2, limit: 1024)
                        let request = try JSONDecoder().decode(HelperRequest.self, from: data)
                        try writeMessage(handler(request), to: client)
                    } catch {
                        try? writeMessage(HelperResponse(error: error.localizedDescription), to: client)
                    }
                }
            }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        } catch { close(fd); throw error }
    }
    deinit { source?.cancel() }
}

private func helperReadMessage(_ fd: Int32, timeout: Double, limit: Int) throws -> Data {
    let deadline = BusyTime.now + timeout
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < limit {
        let remaining = deadline - BusyTime.now
        guard remaining > 0 else { throw BusyError.message("Helper response timed out.") }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { throw BusyError.message("Helper response timed out.") }
        let count = recv(fd, &buffer, min(buffer.count, limit - data.count), MSG_DONTWAIT)
        if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
        guard count > 0 else { throw BusyError.message("Helper closed the connection.") }
        if let end = buffer[..<count].firstIndex(of: 10) {
            data.append(contentsOf: buffer[..<end])
            return data
        }
        data.append(contentsOf: buffer[..<count])
    }
    throw BusyError.message("Helper message is too large.")
}
