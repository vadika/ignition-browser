import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sessions = SessionManager.shared
    private var statusItem: NSStatusItem?
    private var servicesProvider: ServicesProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: no Dock icon, and must NOT quit when the (only) window — the
        // first-run progress sheet — closes. Without this the app exited right after the
        // base build finished and never stayed resident in the menu bar.
        NSApp.setActivationPolicy(.accessory)
        sessions.sweepOrphans()
        installStatusItem()
        registerServices()
        let config = Config.resolve()
        if !FirstRun.isComplete(config) {
            runFirstRun(config)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - First run

    private var firstRunWindow: NSWindow?

    private func runFirstRun(_ config: Config) {
        let label = NSTextField(labelWithString: "Preparing Ignition Browser…")
        label.frame = NSRect(x: 20, y: 24, width: 360, height: 24)
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 56, width: 360, height: 20))
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Ignition Browser"
        win.contentView?.addSubview(label)
        win.contentView?.addSubview(spinner)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        firstRunWindow = win

        DispatchQueue.global().async {
            do {
                try FirstRun.run(config) { msg in
                    DispatchQueue.main.async { label.stringValue = msg }
                }
                DispatchQueue.main.async {
                    self.firstRunWindow?.close()
                    self.firstRunWindow = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.firstRunWindow?.close()
                    self.firstRunWindow = nil
                    let a = NSAlert()
                    a.messageText = "Setup failed"
                    a.informativeText = "\(error)"
                    a.runModal()
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // "flame" = ignition. Template SF Symbol so it adapts to light/dark menu bar;
            // fall back to a title if the symbol is unavailable.
            if let img = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Ignition Browser") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "IB"
            }
        }

        let menu = NSMenu()
        menu.addItem(
            withTitle: "New Ignition Browser",
            action: #selector(newSession),
            keyEquivalent: "n"
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.menu = menu
        statusItem = item
    }

    @objc private func newSession() {
        // No URL = about:blank.
        sessions.openSession(url: nil)
    }

    // MARK: - Services

    private func registerServices() {
        let provider = ServicesProvider(sessions: sessions)
        servicesProvider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
    }
}
