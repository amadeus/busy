import AppKit
import BusyCore
import Darwin

final class BusyAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var instanceLock: BusyInstanceLock?
    private let server = BusyServer()
    private let prevention = SleepPrevention()
    private let batteryMonitor = BatteryMonitor()
    private var session = BusySession()
    private var battery = BatteryState(percent: nil, onBattery: false, hasBattery: false)
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var signals: [DispatchSourceSignal] = []
    private var quitting = false
    private var pendingStop = false
    private var menuIsOpen = false
    private let helperToken = UUID().uuidString
    private var helperActive = false
    private var helperAttempted = false
    private var helperRenewalInFlight = false
    private let helperQueue = DispatchQueue(label: "app.busy.helper.client")
    private var lastHelperRenewal: Double = 0
    private var cliLaunchID: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--from-cli"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    private let settingsStore = BusySettingsStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            instanceLock = try BusyInstanceLock()
            try? FileManager.default.removeItem(at: BusyPaths.directory.appendingPathComponent("startup-error.json"))
            session = BusySession(batteryCutoff: settingsStore.loadBatteryCutoff())
            if let request = try initialRequest() {
                try session.apply(request, now: BusyTime.now)
                if request.batteryCutoff != nil { try settingsStore.saveBatteryCutoff(session.batteryCutoff) }
            }
            battery = batteryMonitor.read()
            guard session.endReason(battery: battery, now: BusyTime.now) == nil else {
                throw BusyError.message("Battery is at or below the cutoff, or its level is unavailable.")
            }
            try prevention.start()
            if BusyHelperClient.isInstalled {
                helperAttempted = true
                try BusyHelperClient.acquire(token: helperToken, batteryCutoff: session.batteryCutoff)
                helperActive = true
                lastHelperRenewal = BusyTime.now
            }
            battery = batteryMonitor.read()
            if let reason = session.endReason(battery: battery, now: BusyTime.now) {
                throw BusyError.message(reason == .durationElapsed
                    ? "The session duration ended during startup."
                    : "Battery is at or below the cutoff, or its level is unavailable.")
            }
            try server.start(handler: { [weak self] request in
                self?.handle(request) ?? BusyResponse(error: "Busy is stopping.")
            }, didReply: { [weak self] _ in
                guard let self else { return }
                if self.pendingStop { self.quit() }
            })
            createMenuBarItem()
            batteryMonitor.onChange = { [weak self] in self?.tick() }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timer, forMode: .eventTracking)
            self.timer = timer
            for value in [SIGTERM, SIGINT, SIGHUP] {
                signal(value, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
                source.setEventHandler { [weak self] in self?.quit() }
                source.resume()
                signals.append(source)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        } catch {
            fputs("Busy: \(error.localizedDescription)\n", stderr)
            // A duplicate launch must not unlink the running app's socket.
            if instanceLock != nil {
                stopKeepingAwake()
                recordStartupError(error.localizedDescription)
                if cliLaunchID == nil { showError(error.localizedDescription) }
            }
            NSApp.terminate(nil)
        }
    }

    private func initialRequest() throws -> BusyRequest? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--initial-request") else { return nil }
        guard index + 1 < args.count, let data = Data(base64Encoded: args[index + 1]) else {
            throw BusyError.message("Invalid initial CLI request.")
        }
        let request = try JSONDecoder().decode(BusyRequest.self, from: data)
        try request.validate()
        guard request.action == .update else { throw BusyError.message("Initial request must update settings.") }
        return request
    }

    private func currentStatus() -> BusyStatus {
        BusyStatus(active: !quitting && !pendingStop, durationSeconds: session.durationSeconds,
                   remainingSeconds: session.remaining(at: BusyTime.now), batteryPercent: battery.percent,
                   onBattery: battery.onBattery, batteryCutoff: session.batteryCutoff, closedLidSupported: helperActive)
    }

    private func handle(_ request: BusyRequest) -> BusyResponse {
        guard !quitting && !pendingStop else { return BusyResponse(error: "Busy is stopping.") }
        do {
            try request.validate()
            battery = batteryMonitor.read()
            switch request.action {
            case .status: break
            case .stop: pendingStop = true
            case .update:
                let previous = session
                try session.apply(request, now: BusyTime.now)
                if request.batteryCutoff != nil {
                    do { try settingsStore.saveBatteryCutoff(session.batteryCutoff) } catch { session = previous; throw error }
                    renewHelperIfNeeded(force: true)
                }
            }
            if session.endReason(battery: battery, now: BusyTime.now) != nil { pendingStop = true }
            refreshMenu()
            return BusyResponse(status: currentStatus())
        } catch { return BusyResponse(error: error.localizedDescription) }
    }

    private func tick() {
        guard !quitting else { return }
        if pendingStop { quit(); return }
        battery = batteryMonitor.read()
        if session.endReason(battery: battery, now: BusyTime.now) != nil { quit(); return }
        renewHelperIfNeeded()
        refreshMenu()
    }

    private func renewHelperIfNeeded(force: Bool = false) {
        guard helperActive, !quitting, !pendingStop, !helperRenewalInFlight,
              force || BusyTime.now - lastHelperRenewal >= 3 else { return }
        helperRenewalInFlight = true
        let cutoff = session.batteryCutoff
        let token = helperToken
        helperQueue.async { [weak self] in
            let result = Result { try BusyHelperClient.renew(token: token, batteryCutoff: cutoff) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.helperRenewalInFlight = false
                guard !self.quitting else { return }
                switch result {
                case .success:
                    self.lastHelperRenewal = BusyTime.now
                    // A setting may have changed while the previous request ran.
                    if self.session.batteryCutoff != cutoff { self.renewHelperIfNeeded(force: true) }
                case .failure(let error):
                    fputs("Busy: \(error.localizedDescription)\n", stderr)
                    self.quit()
                }
            }
        }
    }

    @objc private func didWake() { tick() }

    private func createMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Busy")
        item.button?.image?.isTemplate = true
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        guard let statusItem, !menuIsOpen else { return }
        let menu = NSMenu()
        menu.delegate = self
        addInfo("Busy is keeping your Mac awake", to: menu)
        if let remaining = session.remaining(at: BusyTime.now) {
            addInfo("Time remaining: \(formatTime(remaining))", to: menu)
        } else { addInfo("Duration: Unlimited", to: menu) }
        if let percent = battery.percent {
            addInfo("Battery: \(percent)% — \(battery.onBattery ? "on battery" : "plugged in")", to: menu)
        } else { addInfo(battery.hasBattery ? "Battery level unavailable" : "Power: Connected", to: menu) }
        addInfo("Battery cutoff: \(session.batteryCutoff)%", to: menu)
        addInfo(helperActive ? "Closed-lid sleep prevention is active" : "Closed-lid sleep prevention requires the helper", to: menu)
        menu.addItem(.separator())
        let duration = NSMenu()
        for (label, seconds) in [("Unlimited", 0), ("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200)] {
            let item = NSMenuItem(title: label, action: #selector(setDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = (seconds == 0 && session.durationSeconds == nil) || session.durationSeconds == Double(seconds) ? .on : .off
            duration.addItem(item)
        }
        let customDuration = NSMenuItem(title: "Custom…", action: #selector(customDuration), keyEquivalent: "")
        customDuration.target = self
        duration.addItem(customDuration)
        let durationItem = NSMenuItem(title: "Duration", action: nil, keyEquivalent: "")
        durationItem.submenu = duration
        menu.addItem(durationItem)
        let cutoffs = NSMenu()
        for value in [10, 15, 20, 25, 30, 50] {
            let item = NSMenuItem(title: "\(value)%", action: #selector(setCutoff(_:)), keyEquivalent: "")
            item.tag = value
            item.target = self
            item.state = session.batteryCutoff == value ? .on : .off
            cutoffs.addItem(item)
        }
        let customCutoff = NSMenuItem(title: "Custom…", action: #selector(customCutoff), keyEquivalent: "")
        customCutoff.target = self
        cutoffs.addItem(customCutoff)
        let cutoffItem = NSMenuItem(title: "Battery cutoff", action: nil, keyEquivalent: "")
        cutoffItem.submenu = cutoffs
        menu.addItem(cutoffItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Busy", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.toolTip = session.remaining(at: BusyTime.now).map { "Busy — \(formatTime($0)) remaining" } ?? "Busy — unlimited"
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false; refreshMenu() }

    private func addInfo(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(ceil(seconds))
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }

    @objc private func setDuration(_ sender: NSMenuItem) {
        updateFromMenu(BusyRequest(action: .update, durationSeconds: sender.tag == 0 ? nil : Double(sender.tag), clearDuration: sender.tag == 0))
    }
    @objc private func setCutoff(_ sender: NSMenuItem) {
        updateFromMenu(BusyRequest(action: .update, batteryCutoff: sender.tag))
    }
    @objc private func customDuration() {
        guard let value = prompt(title: "Session duration", message: "Enter a duration in minutes.", initial: "60") else { return }
        guard let minutes = Double(value), minutes.isFinite else { showError("Enter a valid number of minutes."); return }
        updateFromMenu(BusyRequest(action: .update, durationSeconds: minutes * 60))
    }
    @objc private func customCutoff() {
        guard let value = prompt(title: "Battery cutoff", message: "Quit Busy at or below this percentage while on battery.", initial: String(session.batteryCutoff)) else { return }
        guard let cutoff = Int(value) else { showError("Enter a whole percentage from 1 to 100."); return }
        updateFromMenu(BusyRequest(action: .update, batteryCutoff: cutoff))
    }

    private func updateFromMenu(_ request: BusyRequest) {
        let response = handle(request)
        if let error = response.error { showError(error) }
        if pendingStop { quit() }
    }

    private func prompt(title: String, message: String, initial: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Busy couldn't apply that setting"
        alert.informativeText = text
        alert.runModal()
    }
    private func recordStartupError(_ message: String) {
        let object = ["id": cliLaunchID ?? "", "error": message]
        if let data = try? JSONEncoder().encode(object) {
            try? data.write(to: BusyPaths.directory.appendingPathComponent("startup-error.json"), options: .atomic)
        }
    }
    private func stopKeepingAwake() {
        prevention.stop()
        server.stop()
        timer?.invalidate()
        if helperAttempted {
            helperAttempted = false
            helperActive = false
            // A timed-out acquire may still have succeeded in the helper.
            try? BusyHelperClient.release(token: helperToken)
        }
    }
    @objc private func quitFromMenu() { quit() }
    private func quit() {
        guard !quitting else { return }
        quitting = true
        stopKeepingAwake()
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        stopKeepingAwake()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
