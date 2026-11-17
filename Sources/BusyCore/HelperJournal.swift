import Foundation
import Darwin

public final class HelperFileJournal: HelperRecoveryJournal {
    private let directory: String
    private let path: String
    private let expectedOwner: uid_t

    public init(directory: String, expectedOwner: uid_t = 0) {
        self.directory = directory
        self.path = directory + "/journal.json"
        self.expectedOwner = expectedOwner
    }
    public func isPending() throws -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return false }
            throw BusyError.message("Cannot inspect sleep recovery journal.")
        }
        guard info.st_uid == expectedOwner, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size < 1024 else {
            throw BusyError.message("Unsafe sleep recovery journal.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data == Data("{\"restoreSleepEnabled\":true}\n".utf8) else {
            throw BusyError.message("Sleep recovery journal is invalid; administrator repair is required.")
        }
        return true
    }
    public func prepare() throws {
        guard try !isPending() else { throw BusyError.message("Sleep recovery is still pending.") }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BusyError.message("Cannot create sleep recovery journal.") }
        defer { close(fd) }
        let bytes = Array("{\"restoreSleepEnabled\":true}\n".utf8)
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count, fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else {
            // No power setting has been changed yet. A partial journal must not
            // be mistaken for a successfully prepared transaction.
            unlink(path)
            throw BusyError.message("Cannot persist sleep recovery journal.")
        }
        try syncDirectory()
    }
    public func clear() throws {
        if unlink(path) != 0 && errno != ENOENT {
            throw BusyError.message("Cannot remove sleep recovery journal.")
        }
        try syncDirectory()
    }
    private func syncDirectory() throws {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BusyError.message("Cannot open helper recovery directory.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw BusyError.message("Cannot synchronize helper recovery directory.") }
    }
}
