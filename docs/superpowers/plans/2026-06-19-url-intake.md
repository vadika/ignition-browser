# URL Intake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit opt-in URL intake — a drop-under-the-menu-bar entry panel (⌥⌘I hotkey + "Open URL…" menu), an "Open Clipboard URL" item, and a version row — all feeding the existing `SessionManager.openSession(url:)`.

**Architecture:** A borderless `NSPanel` hosts the typed-entry UX (NSMenu-embedded text fields are unreliable). A ~30-line Carbon `RegisterEventHotKey` wrapper provides a global hotkey with no Accessibility permission and no SPM dependency. `AppDelegate` owns both and wires three new menu items. Every surface validates through the existing `URLValidator.normalize` and calls the existing `SessionManager.shared.openSession(url:)`.

**Tech Stack:** Swift 6, AppKit, Carbon.HIToolbox (hotkey), XCTest. No new dependencies.

---

## File Structure

- Create `Sources/IgnitionBrowser/URLEntryPanel.swift` — the entry panel + pure `initialText(clipboard:)` helper.
- Create `Sources/IgnitionBrowser/HotKey.swift` — Carbon global-hotkey wrapper.
- Modify `Sources/IgnitionBrowser/AppDelegate.swift` — menu items, version row, hotkey install, panel ownership, clipboard-item enable/disable.
- Create `Tests/IgnitionBrowserTests/URLEntryPanelTests.swift` — unit test for `initialText`.

Existing reused (no change): `URLValidator.normalize`, `SessionManager.shared.openSession(url:)`.

---

### Task 1: Clipboard → panel prefill helper (TDD)

The one piece of pure logic: the panel pre-fills its field with a **normalized** URL when the clipboard holds a valid http(s) URL, else empty. Testable without AppKit.

**Files:**
- Create: `Sources/IgnitionBrowser/URLEntryPanel.swift`
- Test: `Tests/IgnitionBrowserTests/URLEntryPanelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/IgnitionBrowserTests/URLEntryPanelTests.swift`:

```swift
import XCTest
@testable import IgnitionBrowser

final class URLEntryPanelTests: XCTestCase {
    func testValidClipboardURLIsNormalized() {
        // A valid http(s) URL is returned in canonical absoluteString form.
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: "https://example.com/path"),
                       "https://example.com/path")
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: "  http://x  "),
                       "http://x")
    }

    func testNonURLClipboardGivesEmpty() {
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: "just some text"), "")
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: "javascript:alert(1)"), "")
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: "file:///etc/passwd"), "")
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: nil), "")
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: ""), "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails (compile error: no such type/member)**

Run: `swift test --filter URLEntryPanelTests`
Expected: FAIL — `cannot find 'URLEntryPanel' in scope` (file not created yet).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/IgnitionBrowser/URLEntryPanel.swift` with just the helper for now:

```swift
import AppKit

/// Drop-under-the-menu-bar panel for typing/pasting a URL to open in a throwaway VM.
/// (Full UI is added in Task 2; this is the testable prefill helper.)
@MainActor
final class URLEntryPanel: NSObject {
    /// Initial field text: a normalized URL if `clipboard` holds a valid http(s) URL, else "".
    nonisolated static func initialText(clipboard: String?) -> String {
        guard let clipboard, let url = URLValidator.normalize(clipboard) else { return "" }
        return url.absoluteString
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter URLEntryPanelTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/IgnitionBrowser/URLEntryPanel.swift Tests/IgnitionBrowserTests/URLEntryPanelTests.swift
git commit -m "urlpanel: clipboard prefill helper (initialText) + tests"
```

---

### Task 2: Entry panel UI

Flesh out `URLEntryPanel` into a working borderless panel: text field, Enter→open, Esc/resign→close, invalid→red border, positioned under the status item. UI is not headless-testable — verify by build + manual run.

**Files:**
- Modify: `Sources/IgnitionBrowser/URLEntryPanel.swift`

- [ ] **Step 1: Replace the file with the full panel**

Overwrite `Sources/IgnitionBrowser/URLEntryPanel.swift`:

```swift
import AppKit

/// Drop-under-the-menu-bar panel for typing/pasting a URL to open in a throwaway VM.
/// A panel (not an NSMenu-embedded field) because menu text input is unreliable.
@MainActor
final class URLEntryPanel: NSObject, NSWindowDelegate {
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
        // Esc to cancel: NSTextField sends cancelOperation up the responder chain.
        p.contentView?.addSubview(field)
        return p
    }

    private func position(_ panel: NSPanel, under statusItem: NSStatusItem?) {
        guard let btnWin = statusItem?.button?.window else { panel.center(); return }
        let f = btnWin.frame
        // Right-align the panel under the icon, 6px gap below the menu bar.
        let x = min(f.maxX - panel.frame.width, (statusItem?.button?.window?.screen ?? NSScreen.main)!.frame.maxX - panel.frame.width - 8)
        let y = f.minY - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - actions

    @objc private func submit() {
        guard let url = URLValidator.normalize(field.stringValue) else {
            field.layer?.borderColor = NSColor.systemRed.cgColor
            field.wantsLayer = true
            field.layer?.borderWidth = 2
            field.layer?.cornerRadius = 6
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

    // Esc inside the field: NSWindow.cancelOperation fires on the panel.
    override func cancelOperation(_ sender: Any?) { close() }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `ok (build complete)`.

- [ ] **Step 3: Manual verify (dev run)**

Run: `swift run IgnitionBrowser` (leave first-run/base alone if already built). There is no menu wiring yet, so temporarily verify by adding a throwaway call — SKIP if you prefer to verify after Task 4. (No code change committed here beyond the panel.)

- [ ] **Step 4: Commit**

```bash
git add Sources/IgnitionBrowser/URLEntryPanel.swift
git commit -m "urlpanel: borderless entry panel (enter opens, esc/resign closes, red on invalid)"
```

---

### Task 3: Carbon global hotkey wrapper

**Files:**
- Create: `Sources/IgnitionBrowser/HotKey.swift`

- [ ] **Step 1: Write the wrapper**

Create `Sources/IgnitionBrowser/HotKey.swift`:

```swift
import AppKit
import Carbon.HIToolbox

/// One global hotkey via Carbon RegisterEventHotKey. No Accessibility permission needed
/// (unlike NSEvent global monitors) and no SPM dependency. Fires `handler` on press.
/// ponytail: handles a single hotkey per instance; that's all the app needs.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private let id: UInt32

    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    /// keyCode = Carbon virtual keycode (e.g. kVK_ANSI_I = 34).
    /// modifiers = Carbon mask (e.g. UInt32(optionKey | cmdKey)).
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.id = HotKey.nextID
        HotKey.nextID += 1

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), HotKey.callback, 1, &spec, nil, &handlerRef)

        let hkID = EventHotKeyID(signature: OSType(0x49474E54), id: id) // 'IGNT'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        HotKey.instances[id] = self
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        HotKey.instances[id] = nil
    }

    private static let callback: EventHandlerUPP = { _, event, _ in
        var hkID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        let id = hkID.id
        DispatchQueue.main.async { HotKey.instances[id]?.handler() }
        return noErr
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `ok (build complete)`.

- [ ] **Step 3: Commit**

```bash
git add Sources/IgnitionBrowser/HotKey.swift
git commit -m "hotkey: Carbon RegisterEventHotKey wrapper (no Accessibility permission)"
```

---

### Task 4: Wire menu items, hotkey, panel into AppDelegate

**Files:**
- Modify: `Sources/IgnitionBrowser/AppDelegate.swift`

- [ ] **Step 1: Add stored properties**

In `AppDelegate` (after `private var servicesProvider: ServicesProvider?`), add:

```swift
    private var urlPanel: URLEntryPanel?
    private var hotKey: HotKey?
```

- [ ] **Step 2: Create the panel + register the hotkey in applicationDidFinishLaunching**

In `applicationDidFinishLaunching`, replace the body after `registerServices()` so it reads:

```swift
        registerServices()
        installURLEntry()
        let config = Config.resolve()
        if !FirstRun.isComplete(config) {
            runFirstRun(config)
        }
```

Then add this method (next to `registerServices()`):

```swift
    // MARK: - URL entry (panel + global hotkey)

    private func installURLEntry() {
        let panel = URLEntryPanel { [weak self] url in
            self?.sessions.openSession(url: url)
        }
        urlPanel = panel
        // ⌥⌘I : option+command+I. kVK_ANSI_I = 34.
        hotKey = HotKey(keyCode: 34, modifiers: UInt32(optionKey | cmdKey)) { [weak self] in
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
```

Add the Carbon import at the top of the file (for `optionKey`/`cmdKey`):

```swift
import AppKit
import Carbon.HIToolbox
```

- [ ] **Step 3: Add the menu items and version row**

In `installStatusItem()`, replace the menu-construction block (from `let menu = NSMenu()` through `item.menu = menu`) with:

```swift
        let menu = NSMenu()
        menu.autoenablesItems = true
        menu.delegate = self
        menu.addItem(withTitle: "New Ignition Browser", action: #selector(newSession), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Open URL…", action: #selector(showURLPanel), keyEquivalent: "").target = self

        let clip = NSMenuItem(title: "Open Clipboard URL", action: #selector(openClipboardURL), keyEquivalent: "")
        clip.target = self
        clipboardItem = clip
        menu.addItem(clip)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal Logs in Finder", action: #selector(revealLogs), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let versionItem = NSMenuItem(title: "Ignition Browser v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
```

Add the `clipboardItem` stored property (near the other properties):

```swift
    private var clipboardItem: NSMenuItem?
```

- [ ] **Step 4: Enable/disable "Open Clipboard URL" on menu open**

Make `AppDelegate` conform to `NSMenuDelegate` and reflect clipboard validity. Add to the class (e.g. after `installURLEntry`):

```swift
    func menuWillOpen(_ menu: NSMenu) {
        let s = NSPasteboard.general.string(forType: .string)
        clipboardItem?.isEnabled = (s.flatMap(URLValidator.normalize) != nil)
    }
```

And add the conformance to the class declaration:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
```

> Note: with `menu.autoenablesItems = true`, an item with a valid `target`/`action` is auto-enabled; `menuWillOpen` overrides the clipboard item explicitly. Because `clipboardItem.action` always has a target, the explicit set in `menuWillOpen` is what drives its grey-out.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `ok (build complete)`.

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: PASS (existing tests + `URLEntryPanelTests`).

- [ ] **Step 7: Manual end-to-end verify**

Run: `swift run IgnitionBrowser`. Verify:
1. Menu shows: New Ignition Browser, Open URL…, Open Clipboard URL, ──, Reveal Logs, ──, "Ignition Browser vX.Y.Z" (greyed), Quit.
2. Copy `https://example.com`, open the menu → "Open Clipboard URL" is **enabled**; copy plain text → it is **greyed**.
3. Press **⌥⌘I** → panel drops under the menu-bar icon, prefilled with the clipboard URL (selected). Edit, press **Enter** → a session opens with that URL. Press **Esc** / click away → panel closes, nothing opens.
4. Type garbage in the panel, Enter → red border, panel stays open.

- [ ] **Step 8: Commit**

```bash
git add Sources/IgnitionBrowser/AppDelegate.swift
git commit -m "menu: Open URL… (⌥⌘I panel), Open Clipboard URL, version row"
```

---

### Task 5: Ship

- [ ] **Step 1: Bump version**

Edit `Resources/Info.plist`: `CFBundleShortVersionString` `0.0.16` → `0.0.17`.

- [ ] **Step 2: Commit, tag, push**

```bash
git add Resources/Info.plist
git commit -m "release: v0.0.17 (URL intake: entry panel, ⌥⌘I, clipboard, version row)"
git tag v0.0.17
git push origin main
git push origin v0.0.17
```

- [ ] **Step 3: After CI is green, install**

```bash
gh run watch "$(gh run list --workflow=release.yml -L1 --json databaseId -q '.[0].databaseId')" --exit-status
cd /tmp && rm -rf v17 && mkdir v17 && cd v17
gh release download v0.0.17 -R vadika/ignition-browser -p '*.zip' && unzip -q *.zip
spctl -a -vvv -t exec /tmp/v17/IgnitionBrowser.app   # expect: accepted, Notarized Developer ID
osascript -e 'tell application "IgnitionBrowser" to quit'; sleep 2; pkill -f "MacOS/IgnitionBrowser"
rm -rf /Applications/IgnitionBrowser.app
ditto /tmp/v17/IgnitionBrowser.app /Applications/IgnitionBrowser.app
open -a /Applications/IgnitionBrowser.app
rm -rf /tmp/v17
```

---

## Self-Review

**Spec coverage:**
- Mini entry panel → Task 2. ✓
- Global hotkey ⌥⌘I → Task 3 (wrapper) + Task 4 Step 2 (install). ✓
- "Open URL…" menu item → Task 4 Step 3. ✓
- "Open Clipboard URL" + disable-when-invalid → Task 4 Steps 3–4. ✓
- Version row → Task 4 Step 3. ✓
- Prefill-from-clipboard only when valid → Task 1 (helper) + Task 2 (`show`). ✓
- Drop under menu-bar icon → Task 2 `position(_:under:)`. ✓
- Services unchanged → not touched. ✓
- Error handling (red border, disabled clipboard item) → Task 2 `submit`, Task 4 `menuWillOpen`. ✓

**Type consistency:** `URLEntryPanel.initialText(clipboard:)`, `show(under:)`, `HotKey(keyCode:modifiers:handler:)`, `sessions.openSession(url:)`, `statusItem`, `clipboardItem` — names match across tasks.

**Placeholder scan:** No TBD/TODO; all steps contain complete code and exact commands.
