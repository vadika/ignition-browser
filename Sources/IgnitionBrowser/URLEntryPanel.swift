import AppKit

/// Drop-under-the-menu-bar panel for typing/pasting a URL to open in a throwaway VM.
/// A panel (not an NSMenu-embedded field) because menu text input is unreliable.
@MainActor
final class URLEntryPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let onURL: (URL) -> Void
    private var panel: NSPanel?
    private let field = NSTextField()

    init(onURL: @escaping (URL) -> Void) {
        self.onURL = onURL
        super.init()
    }

    /// Initial field text: a normalized URL if `clipboard` holds a valid http(s) URL, else "".
    nonisolated static func initialText(clipboard: String?) -> String {
        guard let clipboard, let url = URLValidator.normalize(clipboard) else { return "" }
        return url.absoluteString
    }

    /// Show the panel just below the status-bar item, prefilled from the clipboard.
    func show(under statusItem: NSStatusItem?) {
        let panel = panel ?? makePanel()
        self.panel = panel

        field.stringValue = Self.initialText(clipboard: NSPasteboard.general.string(forType: .string))
        resetBorder()
        position(panel, under: statusItem)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)   // overtype replaces the prefilled URL
    }

    // MARK: - build

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
                        styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.delegate = self

        field.frame = NSRect(x: 12, y: 7, width: 396, height: 30)
        field.placeholderString = "Open URL in Ignition Browser…"
        field.font = .systemFont(ofSize: 15)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.target = self
        field.action = #selector(submit)
        field.delegate = self
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.layer?.borderColor = NSColor.systemRed.cgColor
        p.contentView?.addSubview(field)
        return p
    }

    private func position(_ panel: NSPanel, under statusItem: NSStatusItem?) {
        guard let btnWin = statusItem?.button?.window else { panel.center(); return }
        let f = btnWin.frame
        let screen = btnWin.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { panel.center(); return }
        // Right-align the panel under the icon, 6px gap below the menu bar.
        let x = min(f.maxX - panel.frame.width, screen.frame.maxX - panel.frame.width - 8)
        let y = f.minY - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - actions

    @objc private func submit() {
        guard let url = URLValidator.normalize(field.stringValue) else {
            field.layer?.borderWidth = 2          // red (color set in makePanel)
            return
        }
        close()
        onURL(url)
    }

    private func resetBorder() {
        field.layer?.borderWidth = 0
    }

    private func close() {
        panel?.orderOut(nil)
    }

    // Esc / clicking away closes without opening.
    func windowDidResignKey(_ notification: Notification) { close() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):   // Esc
            close()
            return true
        case #selector(NSResponder.insertNewline(_:)):      // Enter
            submit()
            return true
        default:
            return false
        }
    }
}
