import Foundation

public struct BusySettingsStore {
    private struct Settings: Codable { var batteryCutoff: Int }
    private let file: URL

    public init(directory: URL = BusyPaths.directory) {
        file = directory.appendingPathComponent("settings.json")
    }

    public func loadBatteryCutoff() -> Int {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(Settings.self, from: data),
              (1...100).contains(settings.batteryCutoff) else { return 20 }
        return settings.batteryCutoff
    }

    public func saveBatteryCutoff(_ cutoff: Int) throws {
        try BusyRequest(action: .update, batteryCutoff: cutoff).validate()
        let data = try JSONEncoder().encode(Settings(batteryCutoff: cutoff))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
