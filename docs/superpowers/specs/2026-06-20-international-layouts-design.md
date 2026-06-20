# International keyboard layouts — design

Date: 2026-06-20

## Goal

Let non-US users type in the disposable browser. Scope is **keyboard layouts only**
(Cyrillic, German, AZERTY, Spanish, …) — not dead-key composition or full IME. The guest
layout follows the macOS layout automatically, with no manual toggle.

This is a **cross-repo** feature: it lives in `firecracker-mac` (the `boot` binary's GUI input
handler `spike/src/bin/display_sink.rs` and the guest rootfs build
`kimage/build/build-rootfs-browser.sh`). No changes to the Swift `ignition-browser` app.

## Background

Today `display_sink` sends the **physical key position** (winit `PhysicalKey::Code` →
`map_keycode()` → Linux evdev scancode) to the guest via virtio-input. The guest's `cage`
(Wayland) compositor applies a fixed US xkb keymap, so non-US layouts and the host's
selected layout are ignored.

The guest keymap is fixed at `cage` startup (`XKB_DEFAULT_LAYOUT`) and Wayland gives no
runtime keymap reload — so we cannot reconfigure the guest layout per-session. Instead we
bake **all** candidate layouts as xkb **groups** once, and switch the active *group* (cheap,
client-driveable via a key) to match the host.

## Approach

Keep sending physical scancodes (unchanged). Before each keystroke, make the guest's active
xkb **group** match the current macOS layout by injecting group-cycle keys.

## Components

### 1. Guest keymap (rootfs build — `build-rootfs-browser.sh`)

In the `cage-kiosk` service env, replace the single `XKB_DEFAULT_LAYOUT=us` with a fixed,
ordered **superset** and a single-key group cycle:

```sh
export XKB_DEFAULT_LAYOUT="us,ru,de,fr,es,it,ua,pl"
export XKB_DEFAULT_OPTIONS="grp:sclk_toggle"   # Scroll Lock = next group
```

- The order is **fixed and authoritative** — `display_sink`'s lookup table indexes into it.
- `grp:sclk_toggle` binds Scroll Lock to "advance to next group"; Scroll Lock is otherwise
  unused in the browser. No `grp_led` (the guest has no Scroll Lock LED).
- The list is the documented superset; adding a layout later means appending here AND to the
  host table (§2), then a rootfs rebuild. Keep both in sync (a comment in each points to the other).

### 2. Layout → group table + group sync (`display_sink.rs`)

- **`LAYOUTS: &[(&str, &str)]`** — ordered list of `(macOS input-source id, xkb name)`, e.g.
  `("com.apple.keylayout.US","us"), ("com.apple.keylayout.Russian","ru"),
  ("com.apple.keylayout.German","de"), …`. The order MUST match
  `XKB_DEFAULT_LAYOUT` in §1 — the array index *is* the xkb group index. One source of truth.
- **`current_macos_group() -> usize`** — calls `TISCopyCurrentKeyboardInputSource` +
  `TISGetInputSourceProperty(kTISPropertyInputSourceID)` (via `core-foundation` /
  `objc2`), looks the id up in `LAYOUTS`, returns its index; unknown → `0` (us). Cheap;
  called per keystroke.
- **State:** `display_sink` tracks `guest_group: usize` (starts `0`; `cage` boots at group 0).
- **`sync_group(&mut self)`** — `target = current_macos_group()`; while `guest_group != target`,
  inject a `KEY_SCROLLLOCK` press+release (advances the guest group by one, wrapping over
  `LAYOUTS.len()`), incrementing `guest_group mod LAYOUTS.len()`. Wrapping cycle reaches any
  target in ≤ N-1 presses.
- **Hook:** in the `WindowEvent::KeyboardInput` handler, on a key **press** of a normal
  (non-hotkey) key, call `sync_group()` *before* emitting the physical scancode. Releases and
  the `⌃⌥` host-hotkey path are untouched.

### 3. Snapshot interaction

`browser-base` is built once with the superset keymap, so the baked snapshot already has all
groups and starts at group 0. On restore, `guest_group` is reset to 0 in `display_sink`
(matching a freshly-restored cage at group 0), so the host model and guest stay aligned. The
existing recipe-version / guest-stamp bump forces a base rebuild when the rootfs changes.

## Data flow

```
keypress ─▶ display_sink: sync_group()
              target = TIS current macOS layout → LAYOUTS index
              inject KEY_SCROLLLOCK × (target - guest_group mod N)  ─▶ guest cage advances xkb group
            then emit the physical scancode (unchanged) ─▶ guest types in the now-correct layout
```

## Error handling / edge cases

- **Unknown macOS layout** (not in `LAYOUTS`): target = 0 (us). The user falls back to US
  rather than getting garbage; log once to stderr.
- **Group desync** (something else moved the guest group): the per-keystroke `sync_group`
  re-asserts the target every press, so a stray desync self-corrects on the next key. The
  user-facing manual toggle is *not* exposed (only Scroll Lock cycles, which the user never
  presses), so the host stays authoritative.
- **Snapshot restore**: reset `guest_group = 0` on the restore path so the model matches cage.
- **Modifier/shortcut keys** (`⌃`, `⌘`, arrows, Enter, Backspace): unaffected — `sync_group`
  only runs before normal key presses, and group choice doesn't change those evdev codes.

## Testing

- **Unit (`display_sink.rs`):** `sync_group` cycle math — from `guest_group=0`, target=3 →
  3 Scroll Lock presses, `guest_group=3`; wrap case target=1 with `guest_group=N-1` →
  2 presses landing on 1. Table integrity: `LAYOUTS.len()` matches the `XKB_DEFAULT_LAYOUT`
  group count (assert in a test against a hardcoded expected count).
- **Manual (HVF):** set macOS to Russian, type in the guest Firefox address bar → Cyrillic
  appears; switch macOS to German mid-typing → next keys are German (ß, umlauts via that
  layout). Switch back to US → Latin. Verify `⌃⌥R/S/X` hotkeys and Enter/Backspace still work.

## Decisions

- **Layouts only** — no dead-key composition, no IME (that is the separate text-injection
  project; this scancode+group path doesn't preclude it later).
- **Baked superset, not exact enabled-list** — avoids per-session keymap reconfig (impossible
  under cage at runtime).
- **Poll on keypress, not a `CFNotification` observer** — layout only matters when typing.
- **Cycle + host-tracked index, not absolute-group-select xkb config** — simpler; self-correcting.
- **All in `boot` + 2 rootfs env lines** — no Swift app change, no vsock channel, no cage patch.

## Out of scope (YAGNI)

- Matching the exact set/order of the user's macOS-enabled layouts.
- A live `CFNotification` observer / menu indicator of the current layout.
- Dead keys, AltGr composition, CJK/IME (separate feature; would use a Wayland
  virtual-keyboard text-injection path).
- A user-visible manual layout toggle inside the guest.
