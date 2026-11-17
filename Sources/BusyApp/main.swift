import AppKit
import BusyCore

let app = NSApplication.shared
let delegate = BusyAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
