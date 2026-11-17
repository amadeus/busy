import BusyCore
import Foundation

private struct Options {
    enum Command { case start, status, stop, help }
    var command: Command = .start
    var durationSeconds: Double?
    var clearDuration = false
    var batteryCutoff: Int?
    var json = false

    var request: BusyRequest {
        BusyRequest(
            action: command == .stop ? .stop : hasChanges ? .update : .status,
            durationSeconds: durationSeconds,
            clearDuration: clearDuration,
            batteryCutoff: batteryCutoff
        )
    }

    var hasChanges: Bool { durationSeconds != nil || clearDuration || batteryCutoff != nil }

    init(arguments: [String]) throws {
        var index = 0
        var seen = Set<String>()
        if let first = arguments.first, !first.hasPrefix("-") {
            switch first {
            case "status": command = .status
            case "stop": command = .stop
            case "help": command = .help
            default: throw CLIError("Unknown command '\(first)'. Run busy --help for usage.")
            }
            index += 1
        }
        while index < arguments.count {
            let argument = arguments[index]
            guard seen.insert(argument).inserted else {
                throw CLIError("Option '\(argument)' was provided more than once.")
            }
            switch argument {
            case "--help", "-h": command = .help
            case "--json": json = true
            case "--duration", "--battery-cutoff":
                index += 1
                guard index < arguments.count else { throw CLIError("Missing value for \(argument).") }
                let value = arguments[index]
                if argument == "--duration" {
                    if value == "unlimited" {
                        clearDuration = true
                    } else {
                        durationSeconds = try Self.parseDuration(value)
                    }
                } else {
                    guard let cutoff = Int(value), (1...100).contains(cutoff) else {
                        throw CLIError("Battery cutoff must be a whole percentage from 1 to 100.")
                    }
                    batteryCutoff = cutoff
                }
            default: throw CLIError("Unknown option '\(argument)'. Run busy --help for usage.")
            }
            index += 1
        }
        if command != .start && command != .help && hasChanges {
            throw CLIError("Use settings with busy directly, without status or stop.")
        }
    }

    static func parseDuration(_ value: String) throws -> Double {
        guard let unit = value.last else { throw CLIError("Duration must look like 30m, 2h, or 90s.") }
        let multiplier: Double
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        default: throw CLIError("Duration must end in s, m, h, or d, or be unlimited.")
        }
        let amount = String(value.dropLast())
        guard !amount.isEmpty,
              amount.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let number = Double(amount), number.isFinite,
              number > 0, (number * multiplier).isFinite,
              number * multiplier >= 1, number * multiplier <= 31_536_000 else {
            throw CLIError("Duration must be between 1 second and 365 days.")
        }
        return number * multiplier
    }
}

private struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private let usage = """
Usage: busy [--duration <time|unlimited>] [--battery-cutoff <percent>] [--json]
       busy status [--json]
       busy stop [--json]

Launch Busy if needed, print its status, and return to the shell.
A running session is preserved unless you supply a setting.

  --duration 2h          Start a fresh countdown (s, m, h, or d; up to 365 days)
  --duration unlimited   Remove the countdown
  --battery-cutoff 25    Save a cutoff from 1 to 100 percent (default: 20)
  --json                 Print machine-readable status
  status                 Show status without launching Busy
  stop                   Quit Busy and allow normal sleep
  --help, -h             Show this help

Battery protection applies on battery power and overrides the timer.
Duration is session-specific; the battery cutoff persists across launches.

Build:   ./scripts/build.sh
Install: ./scripts/install.sh
The installer defaults to /Applications/Busy.app and ~/.local/bin/busy.
For a development build, set BUSY_APP_PATH to the full path of Busy.app.
"""

private func appURL() throws -> URL {
    let fileManager = FileManager.default
    if let override = ProcessInfo.processInfo.environment["BUSY_APP_PATH"] {
        let url = URL(fileURLWithPath: override).standardizedFileURL
        guard fileManager.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/BusyApp").path) else {
            throw CLIError("BUSY_APP_PATH does not point to a built Busy.app: \(override)")
        }
        return url
    }
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let enclosingBundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [enclosingBundle, URL(fileURLWithPath: "/Applications/Busy.app")]
    for candidate in candidates where candidate.pathExtension == "app" {
        if Bundle(url: candidate)?.bundleIdentifier == "com.amadeus.Busy",
           fileManager.fileExists(atPath: candidate.appendingPathComponent("Contents/MacOS/BusyApp").path) {
            return candidate
        }
    }
    throw CLIError("Busy.app was not found. Run ./scripts/build.sh and ./scripts/install.sh, or set BUSY_APP_PATH.")
}

private func launchApp(initialRequest: BusyRequest) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var arguments = ["-g"]
    if let directory = ProcessInfo.processInfo.environment["BUSY_STATE_DIR"], !directory.isEmpty {
        arguments += ["--env", "BUSY_STATE_DIR=\(BusyPaths.directory.path)"]
    }
    arguments += [try appURL().path, "--args", "--from-cli", initialRequest.id.uuidString]
    if initialRequest.action == .update {
        arguments += ["--initial-request", try JSONEncoder().encode(initialRequest).base64EncodedString()]
    }
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CLIError("macOS could not launch Busy.app.") }
}

private struct StartupFailure: Decodable {
    let id: UUID
    let error: String
}

private func startupFailure(for request: BusyRequest) -> String? {
    let path = BusyPaths.directory.appendingPathComponent("startup-error.json")
    guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 16_384),
          let failure = try? JSONDecoder().decode(StartupFailure.self, from: data),
          failure.id == request.id else { return nil }
    return failure.error
}

private func durationDescription(_ seconds: Double) -> String {
    var remaining = max(0, Int(ceil(seconds)))
    let units = [(86_400, "day"), (3_600, "hour"), (60, "minute"), (1, "second")]
    var parts: [String] = []
    for (size, name) in units {
        let count = remaining / size
        if count > 0 {
            parts.append("\(count) \(name)\(count == 1 ? "" : "s")")
            remaining %= size
        }
        if parts.count == 2 { break }
    }
    return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
}

private func printResponse(_ response: BusyResponse, json: Bool) throws {
    if let error = response.error { throw CLIError(error) }
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(response), as: UTF8.self))
        return
    }
    guard let status = response.status else { throw CLIError("Busy returned no status.") }
    guard status.active else {
        print("Busy is not running.")
        return
    }
    print("Busy is keeping your Mac awake.")
    if let duration = status.durationSeconds, let remaining = status.remainingSeconds {
        print("Duration: \(durationDescription(duration)) — \(durationDescription(remaining)) remaining")
    } else {
        print("Duration: Unlimited")
    }
    if let percent = status.batteryPercent {
        print("Battery: \(percent)% — \(status.onBattery ? "on battery" : "plugged in")")
    } else {
        print("Battery: Unavailable — \(status.onBattery ? "on battery" : "external power")")
    }
    print("Battery cutoff: \(status.batteryCutoff)%")
    if status.closedLidSupported {
        print("Closed lid: Sleep prevention active")
    } else {
        print("Closed lid: Not supported; closing the lid may put the Mac to sleep.")
    }
}

private func run() throws {
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
    if options.command == .help { print(usage); return }
    let request = options.request
    let response: BusyResponse
    do {
        response = try BusyClient.send(request)
    } catch {
        // Only a missing/refused endpoint means the app needs to launch. Protocol
        // and permission errors must be reported instead of starting another copy.
        guard case BusyError.notRunning = error else { throw error }
        if options.command != .start {
            if options.json {
                print("{\"status\":{\"active\":false}}")
            } else {
                print("Busy is not running.")
            }
            return
        }
        try launchApp(initialRequest: request)
        let deadline = Date().addingTimeInterval(30)
        var launchedResponse: BusyResponse?
        while Date() < deadline {
            do {
                // The app deduplicates the startup request by ID. Sending it
                // again also covers another CLI winning a simultaneous launch.
                launchedResponse = try BusyClient.send(request)
                break
            } catch {
                guard case BusyError.notRunning = error else { throw error }
                if let failure = startupFailure(for: request) { throw CLIError(failure) }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        guard let launchedResponse else {
            throw CLIError("Busy did not become available within 30 seconds. Check its startup error or battery cutoff.")
        }
        response = launchedResponse
    }
    try printResponse(response, json: options.json)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("busy: \(error.localizedDescription)\n".utf8))
    exit(1)
}
