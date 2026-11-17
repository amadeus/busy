import Foundation
import Darwin
import BusyCore

let helperDirectory = "/Library/Application Support/BusyHelper"

func checkRootPath(_ path: String, directory: Bool, privateFile: Bool = true) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_uid == 0,
          info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
          info.st_mode & (privateFile ? 0o077 : 0o022) == 0 else {
        throw BusyError.message("Unsafe helper path: \(path). Reinstall the helper.")
    }
}
