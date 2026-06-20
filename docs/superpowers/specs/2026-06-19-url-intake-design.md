# URL Intake — design

Date: 2026-06-19

## Goal

Add low-friction, **explicit opt-in** ways to send a URL into Ignition Browser. The user
deliberately chooses to open a link in a throwaway VM; Ignition does **not** become the
default browser or intercept system-wide opens.

All new surfaces feed the existing pipeline:
`URLValidator.normalize(String) -> URL?` → `SessionManager.shared.openSession(url:)`
(restore browser-base clone → inject URL over vsock 7777).

## Surfaces (in scope)

1. **Mini entry panel** (typed/edited entry).
2. **Global hotkey** ⌃⌥I → opens the panel.
3. **Menu items** — "Open URL…", "Open Clipboard URL", and a version row.
4. **Services menu** — already shipped (`ServicesProvider`); unchanged.

Out of scope (YAGNI): per-browser extensions, default-handler/interceptor mode,
configurable-hotkey UI, `ignition://` URL scheme, menu-embedded text field.

## Components

### `URLEntryPanel.swift` (new)
Borderless floating `NSPanel` (`.nonactivatingPanel`, `.titled` off, level
`.floating`), single `NSTextField`.

- **Show:** position **under the menu-bar status item** — anchor to
  `statusItem.button.window.frame` (screen coords), drop the panel just below it.
  Pre-fill the field **only if** `URLValidator.normalize(NSPasteboard.general.string(forType:.string))`
  returns non-nil; else empty. `selectText(nil)` so the pre-filled URL is fully selected
  and an overtype replaces it.
- **Enter:** `URLValidator.normalize(field.stringValue)`; nil → set a red focus ring /
  border and keep the panel open (no open, no close). non-nil → `openSession(url:)`, close.
- **Esc** (cancel) or the panel resigning key → close without opening.
- Make the panel key and first-responder so typing lands in the field immediately
  (the reason we use a panel instead of an `NSMenu`-embedded field).

### `HotKey.swift` (new)
~30-line Carbon `RegisterEventHotKey` wrapper. Registers one fixed hotkey
**⌃⌥I** (`controlKey | optionKey`, keycode for `I` = `kVK_ANSI_I` = 34) via
`RegisterEventHotKey` + an `InstallEventHandler` for `kEventHotKeyPressed`. Carbon hotkeys
need **no Accessibility permission** (unlike `NSEvent` global monitors) and no SPM
dependency. Calls a stored handler closure on press → `AppDelegate` shows the panel.
Unregister on `deinit`.

### `AppDelegate.swift` (edit)
- Own a `URLEntryPanel` and a `HotKey`; install the hotkey in
  `applicationDidFinishLaunching`, handler → `panel.show(under: statusItem)`.
- Menu (top → bottom):
  - **New Ignition Browser** (⌘N) — unchanged (about:blank).
  - **Open URL…** — shows the panel.
  - **Open Clipboard URL** — `URLValidator.normalize(clipboard)` → open; the item is
    **disabled** when that is nil. Validate on menu-open via `NSMenuDelegate.menuWillOpen`
    (or `validateMenuItem`) so the enabled state reflects the current clipboard.
  - separator
  - **Reveal Logs in Finder** — unchanged.
  - separator
  - **Ignition Browser v{CFBundleShortVersionString}** — disabled (grayed) info row,
    read from `Bundle.main.infoDictionary`.
  - **Quit** (⌘Q) — unchanged.

## Data flow

```
hotkey ⌃⌥I ─┐
"Open URL…" ─┼─> URLEntryPanel (pre-fill from clipboard if valid) ─Enter─> normalize ─> openSession(url:)
            │
"Open Clipboard URL" ───> normalize(clipboard) ──────────────────────────> openSession(url:)
Services menu (existing) ─> normalize(pasteboard) ───────────────────────> openSession(url:)
```

## Error handling

- Invalid URL in the panel: red border, panel stays open, nothing launches.
- Clipboard has no valid URL: "Open Clipboard URL" disabled (never fires on junk).
- `openSession` failures are already handled inside `SessionManager` (logged, swept).

## Testing

- `URLValidator` already has unit coverage; the clipboard path reuses it.
- Add one assert-based self-check for the "pre-fill only when clipboard is a valid http(s)
  URL" helper (valid URL → pre-fill string; plain text / non-URL → nil/empty).
- Panel focus, hotkey registration, and menu enable/disable are manual-verify (UI).

## Decisions

- Hotkey **⌃⌥I**, fixed (configurable later if needed).
- Panel **drops under the menu-bar icon** (not screen-centered).
- Panel over menu-embedded field — `NSMenu` text input is unreliable.
- Carbon hotkey over `NSEvent` monitor — no Accessibility permission, no dependency.
