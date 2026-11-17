import Foundation
import Darwin
import BusyCore

struct Configuration: Decodable { let authorizedUID: uid_t }

func logFailure(_ error: Error) {
    FileHandle.standardError.write(Data("BusyHelper: \(error.localizedDescription)\n".utf8))
}

func run() throws {
    guard geteuid() == 0 else { throw BusyError.message("BusyHelper must run as administrator.") }
    guard CommandLine.arguments.count == 1 || CommandLine.arguments == [CommandLine.arguments[0], "--restore-only"] else {
        throw BusyError.message("Unknown BusyHelper argument.")
    }
    try checkRootPath("/Library/Application Support", directory: true, privateFile: false)
    try checkRootPath(helperDirectory, directory: true)
    let lockPath = helperDirectory + "/helper.lock"
    let lock = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw BusyError.message("Cannot open helper lock.") }
    defer { close(lock) }
    try checkRootPath(lockPath, directory: false)
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw BusyError.message("BusyHelper is already running.") }
    let lease = HelperLease(power: SystemPower(), journal: HelperFileJournal(directory: helperDirectory), clock: { BusyTime.now })
    try lease.recover()
    if CommandLine.arguments.count == 2 { return }

    let configPath = helperDirectory + "/config.json"
    try checkRootPath(configPath, directory: false)
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
    guard configuration.authorizedUID > 0 else { throw BusyError.message("Helper requires a non-root authorized user.") }
    let runtimePath = "/var/run/com.amadeus.Busy"
    if mkdir(runtimePath, 0o755) != 0 && errno != EEXIST { throw BusyError.message("Cannot create helper socket directory.") }
    try checkRootPath(runtimePath, directory: true, privateFile: false)
    let state = DispatchQueue(label: "app.busy.helper.lease")
    var stopping = false
    let server = HelperServer()
    try server.start(authorizedUID: configuration.authorizedUID) { request in
        state.sync {
            guard !stopping else { return HelperResponse(error: "Busy helper is stopping.") }
            do {
                switch request.action {
                case .acquire:
                    try lease.acquire(token: request.token, cutoff: request.batteryCutoff, battery: readBattery(), now: BusyTime.now)
                case .renew:
                    try lease.renew(token: request.token, cutoff: request.batteryCutoff, battery: readBattery(), now: BusyTime.now)
                case .release:
                    try lease.release(token: request.token)
                }
                return HelperResponse()
            } catch { return HelperResponse(error: error.localizedDescription) }
        }
    }
    let timer = DispatchSource.makeTimerSource(queue: state)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        do { try lease.tick(battery: readBattery(), now: BusyTime.now) }
        catch { logFailure(error) }
    }
    timer.resume()
    var signals: [DispatchSourceSignal] = []
    for value in [SIGTERM, SIGINT] {
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: state)
        source.setEventHandler {
            stopping = true
            do { try lease.recover(); exit(0) }
            catch { logFailure(error); exit(1) }
        }
        source.resume()
        signals.append(source)
    }
    withExtendedLifetime((server, timer, signals)) { dispatchMain() }
}

do { try run() }
catch { logFailure(error); exit(1) }
