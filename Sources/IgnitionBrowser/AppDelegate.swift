import AppKit
import Carbon.HIToolbox
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let sessions = SessionManager.shared
    private var statusItem: NSStatusItem?
    private var servicesProvider: ServicesProvider?
    private var urlPanel: URLEntryPanel?
    private var hotKey: HotKey?
    private var clipboardItem: NSMenuItem?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: no Dock icon, and must NOT quit when the (only) window — the
        // first-run progress sheet — closes. Without this the app exited right after the
        // base build finished and never stayed resident in the menu bar.
        NSApp.setActivationPolicy(.accessory)
        sessions.sweepOrphans()
        installStatusItem()
        registerServices()
        installURLEntry()
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
            let result = Result {
                try FirstRun.run(config) { msg in
                    DispatchQueue.main.async { label.stringValue = msg }
                }
            }
            DispatchQueue.main.async {
                self.firstRunWindow?.close()
                self.firstRunWindow = nil
                // Stay resident no matter what — never NSApp.terminate here. If the base
                // actually got built (a late timeout can throw after the snapshot landed)
                // treat it as done. Only a genuinely incomplete base shows an error, and
                // even then the app stays in the menu bar (relaunch retries first-run).
                if case .failure(let error) = result, !FirstRun.isComplete(config) {
                    let a = NSAlert()
                    a.messageText = "Setup did not finish"
                    a.informativeText = "\(error)\n\nIgnition Browser is still in the menu bar; it will retry the next time you open it."
                    a.runModal()
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
        menu.autoenablesItems = true
        menu.addItem(withTitle: "New Ignition Browser", action: #selector(newSession), keyEquivalent: "n").target = self
        let openURL = NSMenuItem(title: "Open URL…", action: #selector(showURLPanel), keyEquivalent: "i")
        // Surface the ⌃⌥I global hotkey in the menu for discoverability. The real binding is
        // the Carbon hotkey (works system-wide); this only displays the glyph (an accessory
        // app's status menu doesn't process key equivalents globally, so it won't double-fire).
        openURL.keyEquivalentModifierMask = [.control, .option]
        openURL.target = self
        menu.addItem(openURL)

        let clip = NSMenuItem(title: "Open Clipboard URL", action: #selector(openClipboardURL), keyEquivalent: "")
        clip.target = self
        clipboardItem = clip
        menu.addItem(clip)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal Logs in Finder", action: #selector(revealLogs), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let upd = NSMenuItem(title: "Check for Updates…",
                             action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                             keyEquivalent: "")
        upd.target = updaterController
        menu.addItem(upd)
        menu.addItem(.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let versionItem = NSMenuItem(title: "Ignition Browser v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func newSession() {
        // No URL = about:blank.
        sessions.openSession(url: nil)
    }

    @objc private func revealLogs() {
        let dir = SessionManager.logsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: - URL entry (panel + global hotkey)

    private func installURLEntry() {
        let panel = URLEntryPanel { [weak self] url in
            self?.sessions.openSession(url: url)
        }
        urlPanel = panel
        // ⌃⌥I : control+option+I (⌥⌘I clashes with terminal/browser inspectors). kVK_ANSI_I = 34.
        hotKey = HotKey(keyCode: 34, modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.showURLPanel()
        }
    }

    @objc private func showURLPanel() {
        urlPanel?.show(under: statusItem)
    }

    @objc private func openClipboardURL() {
        guard let s = NSPasteboard.general.string(forType: .string),
              let url = URLValidator.normalize(s) else { return }
        sessions.openSession(url: url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openClipboardURL) {
            let s = NSPasteboard.general.string(forType: .string)
            return s.flatMap(URLValidator.normalize) != nil
        }
        return true
    }

    // MARK: - Services

    private func registerServices() {
        let provider = ServicesProvider(sessions: sessions)
        servicesProvider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
    }
}
