import AppKit

// Entry point. Menu-bar agent (no Dock icon): .accessory activation policy.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
