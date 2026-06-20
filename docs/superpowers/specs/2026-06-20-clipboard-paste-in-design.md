# Clipboard sharing (host → guest paste-in) — design

Date: 2026-06-20

> **Status: spec only — implementation postponed.**

## Goal

Paste the Mac clipboard into the throwaway browser (e.g. a password or text into a form). One
direction only: **host → guest**. You deliberately push your data in; the page only sees it if
you then paste into it. Guest → host copy-out is out of scope (a hostile page could spam your
real clipboard).

## Approach (the lazy one)

A menu action reads `NSPasteboard`, sends the text over a new vsock port to a guest listener
that sets the Wayland clipboard with `wl-copy`. You then paste in the guest with its native
`Ctrl+V`. No `boot`/Rust changes — reuses the existing `VsockClient`, `NSPasteboard` reads, and
the `socat VSOCK-LISTEN → script` pattern (ports 7777/9000 already do this).

The clipboard text is **base64-encoded** on the wire so the single-line vsock protocol carries
multi-line / special-character content safely.

## Components

### 1. Guest: `wl-clipboard` + a clipboard listener (`build-rootfs-browser.sh`)

- `apk add wl-clipboard` (alongside the cage stack).
- `/usr/bin/set-clipboard`: reads one base64 line from stdin, decodes it, and runs `wl-copy` in
  the kiosk user's Wayland session (the same `XDG_RUNTIME_DIR=/run/user/1000` + `WAYLAND_DISPLAY`
  the cage-kiosk service uses — confirm the socket name at build time, cage's default is
  `wayland-1`):

  ```sh
  #!/bin/sh
  # One base64 line in (the host clipboard); decode and put it on the kiosk Wayland clipboard.
  IFS= read -r b64
  printf '%s' "$b64" | base64 -d 2>/dev/null \
    | su kiosk -c 'XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 wl-copy' \
    && echo "[set-clipboard] set" > /dev/ttyS0 2>&1
  ```
  `wl-copy` self-daemonizes to hold the selection until the next set; reading the payload from
  stdin (not argv) avoids any shell-interpolation of attacker-influenced text. The socat listener
  runs as root; `su kiosk` drops to the Wayland session owner.
- `socat VSOCK-LISTEN:7778,fork EXEC:/usr/bin/set-clipboard` via `/etc/local.d/setclipboard.start`
  (same pattern as `openurl.start` / `vmid.start`).
- The base build must capture this listener in the snapshot (it starts from `local.d` at boot,
  like the others), so restored sessions have port 7778 live.

### 2. App: "Send Clipboard to Session"

- **`SessionManager.sendClipboardToAll(_ text: String)`** — base64-encode `text`, then for each
  live session push it over that session's vsock UDS: `VsockClient.sendLine(uds, port: 7778,
  line: base64, deadline: 5)`, off the main thread. Push to **all** live sessions (harmless for a
  throwaway; you paste in whichever window is focused). No-op if `text` is empty or there are no
  sessions.
- **`AppDelegate`** menu item **"Send Clipboard to Session"** (near "Open Clipboard URL"): reads
  `NSPasteboard.general.string(forType: .string)` and calls `sendClipboardToAll`. Disabled (via
  the existing `validateMenuItem`) when there is no live session or the clipboard has no string.

## Data flow

```
menu "Send Clipboard to Session" → NSPasteboard string → base64
  → for each live session: VsockClient CONNECT 7778 → send base64 line
  → guest set-clipboard: base64 -d → wl-copy (kiosk Wayland clipboard)
  → user presses Ctrl+V in the guest Firefox → pastes
```

## Error handling

- Empty clipboard or no live session → menu item disabled; `sendClipboardToAll` no-ops.
- vsock push fails (listener not up, session torn down mid-send) → `VsockClient.sendLine` returns
  false after its deadline; logged, best-effort (the menu can be retried).
- Malformed base64 in the guest → `base64 -d` fails, `wl-copy` not run, nothing pasted (no crash).

## Testing

- **Guest (manual / HVF):** push a known string over vsock 7778, then `Ctrl+V` in a guest text
  field → the string appears. Multi-line + non-ASCII via the base64 path.
- **App (unit):** `sendClipboardToAll("")` is a no-op; a non-empty string base64-encodes to the
  expected value (test the encode helper). The vsock push itself is integration/manual (needs a
  live guest).
- The `validateMenuItem` enable/disable mirrors the existing "Open Clipboard URL" test pattern.

## Decisions

- **Host → guest only** (paste-in). Copy-out deferred (isolation hole).
- **Menu-driven**, not `⌘V` interception — no `boot`/Rust pasteboard FFI or key injection.
- **base64 on the wire** so the line-based vsock protocol handles multi-line / special chars.
- **Push to all live sessions** — simplest; per-session targeting is YAGNI for a throwaway.
- New vsock port **7778** (7777 = URL, 9000 = reseed).

## Out of scope (YAGNI)

- Seamless `⌘V` interception (option A: Rust `NSPasteboard` FFI + `wl-copy` push + `Ctrl+V`
  injection in `boot`).
- A `⌃⌥V` global hotkey (add later if the menu round-trip feels heavy).
- Auto-push the clipboard on session start (silently leaks the Mac clipboard into every disposable
  VM; explicit is safer).
- Guest → host copy-out; rich/non-text clipboard flavors (images, files).
