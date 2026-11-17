import Foundation
import Darwin

public enum BusyPaths {
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["BUSY_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Busy", isDirectory: true)
    }
    public static var socketPath: String { directory.appendingPathComponent("control.sock").path }

    public static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw BusyError.message("Busy's control directory must be owned by the current user and must not be a symbolic link.")
        }
        guard chmod(directory.path, 0o700) == 0 else { throw socketError("Secure control directory") }
    }
}

public final class BusyInstanceLock {
    private let descriptor: Int32
    public init() throws {
        try BusyPaths.prepareDirectory()
        let path = BusyPaths.directory.appendingPathComponent("instance.lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw socketError("Open instance lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw BusyError.message("Busy is already running.")
        }
    }
    /// Observe an app that is starting or finishing cleanup without launching a
    /// second process while it still owns the control directory.
    public static func isHeld() throws -> Bool {
        let path = BusyPaths.directory.appendingPathComponent("instance.lock").path
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return false }
            throw socketError("Inspect instance lock")
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        if errno == EWOULDBLOCK { return true }
        throw socketError("Inspect instance lock")
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

func socketError(_ operation: String) -> BusyError {
    .message("\(operation): \(String(cString: strerror(errno)))")
}

func withSocketAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw BusyError.message("Busy's control socket path is too long.")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

func configureSocket(_ fd: Int32) {
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}

func readMessage(_ fd: Int32) throws -> Data {
    let deadline = BusyTime.now + 2
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count <= 16_384 {
        let remaining = deadline - BusyTime.now
        guard remaining > 0 else { throw BusyError.message("Timed out reading control message.") }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { throw BusyError.message("Timed out reading control message.") }
        let count = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            if errno == ECONNRESET { throw BusyError.connectionClosed }
            throw socketError("Read control message")
        }
        guard count > 0 else { throw BusyError.connectionClosed }
        if let end = buffer[..<count].firstIndex(of: 10) {
            data.append(contentsOf: buffer[..<end])
            guard data.count <= 16_384 else { break }
            return data
        }
        data.append(contentsOf: buffer[..<count])
    }
    throw BusyError.message("Control message is too large.")
}

func writeMessage<T: Encodable>(_ value: T, to fd: Int32) throws {
    var data = try JSONEncoder().encode(value)
    data.append(10)
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EPIPE || errno == ECONNRESET { throw BusyError.connectionClosed }
                throw socketError("Write control message")
            }
            guard count > 0 else { throw BusyError.connectionClosed }
            offset += count
        }
    }
}

public enum BusyClient {
    public static func send(_ request: BusyRequest) throws -> BusyResponse {
        try request.validate()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("Create control socket") }
        defer { close(fd) }
        configureSocket(fd)
        try withSocketAddress(BusyPaths.socketPath) { address, length in
            guard connect(fd, address, length) == 0 else {
                if errno == ENOENT || errno == ECONNREFUSED { throw BusyError.notRunning }
                throw socketError("Connect to Busy")
            }
        }
        do {
            try writeMessage(request, to: fd)
            return try JSONDecoder().decode(BusyResponse.self, from: readMessage(fd))
        } catch BusyError.connectionClosed {
            throw BusyError.notRunning
        }
    }
}

/// The caller must retain the instance lock for the server's entire lifetime.
public final class BusyServer {
    private var descriptor: Int32 = -1
    private let queue = DispatchQueue(label: "app.busy.control")
    private var source: DispatchSourceRead?
    public init() {}

    public func start(handler: @escaping (BusyRequest) -> BusyResponse, didReply: @escaping (BusyRequest) -> Void) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("Create control socket") }
        do {
            configureSocket(fd)
            unlink(BusyPaths.socketPath)
            try withSocketAddress(BusyPaths.socketPath) { address, length in
                guard bind(fd, address, length) == 0 else { throw socketError("Bind control socket") }
            }
            guard chmod(BusyPaths.socketPath, 0o600) == 0 else { throw socketError("Secure control socket") }
            guard listen(fd, 8) == 0 else { throw socketError("Listen for CLI") }
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw socketError("Configure control listener") }
            descriptor = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                configureSocket(client)
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
                do {
                    let request = try JSONDecoder().decode(BusyRequest.self, from: readMessage(client))
                    try request.validate()
                    let response = DispatchQueue.main.sync { handler(request) }
                    try writeMessage(response, to: client)
                    DispatchQueue.main.async { didReply(request) }
                } catch {
                    try? writeMessage(BusyResponse(error: error.localizedDescription), to: client)
                }
            }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        } catch {
            close(fd)
            throw error
        }
    }

    public func stop() {
        guard descriptor >= 0 else { return }
        source?.cancel()
        source = nil
        descriptor = -1
        unlink(BusyPaths.socketPath)
    }
    deinit { stop() }
}
