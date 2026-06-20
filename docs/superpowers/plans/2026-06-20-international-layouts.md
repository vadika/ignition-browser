# International Keyboard Layouts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the disposable browser follow the macOS keyboard layout — type Cyrillic/German/AZERTY/etc. — by baking a superset xkb keymap into the guest and switching its active xkb *group* per keystroke to match macOS.

**Architecture:** All changes are in **`firecracker-mac`** (the `boot` binary), not the Swift app. The guest `cage` keymap bakes several layouts as xkb groups (`XKB_DEFAULT_LAYOUT="us,ru,…"`, Scroll Lock cycles groups). `boot`'s GUI input handler (`spike/src/bin/display_sink.rs`) reads the current macOS layout via the Carbon Text Input Sources API, and before forwarding each key press it injects enough `KEY_SCROLLLOCK` events to advance the guest to the matching group. Physical scancodes are otherwise unchanged.

**Tech Stack:** Rust (the `ignition-spike` crate / `boot` bin), `winit` 0.30, `core-foundation` + the Carbon framework (TIS FFI), virtio-input; Linux xkb groups in the Alpine guest rootfs (`kimage/build/build-rootfs-browser.sh`).

> All paths below are relative to the `firecracker-mac` repo root (`/Users/vadikas/firecracker-mac`), which is the ignition submodule. Work there, on a feature branch.

---

## File Structure

- Modify `spike/Cargo.toml` — add the `core-foundation` dependency.
- Modify `spike/src/bin/display_sink.rs` — the `LAYOUTS` table, pure helpers (`group_index`, `cycle_count`), the Carbon TIS reader (`current_macos_group`), a `guest_group` field on `App`, a `sync_group` method, and the call site in `WindowEvent::KeyboardInput`.
- Modify `kimage/build/build-rootfs-browser.sh` — the `cage-kiosk` service xkb env (superset layout + Scroll Lock group cycle).

The xkb group **order** in the rootfs env and the `LAYOUTS` array order are a single shared contract — they must match exactly.

---

### Task 1: Pure helpers + layout table (TDD)

The two pieces of pure logic — mapping a macOS source id to a group index, and the cycle count to reach a target group — plus the authoritative `LAYOUTS` table.

**Files:**
- Modify: `spike/src/bin/display_sink.rs`

- [ ] **Step 1: Write the failing test**

Add to the existing `#[cfg(test)] mod tests { … }` block in `spike/src/bin/display_sink.rs` (it already exists for `match_hotkey`):

```rust
    #[test]
    fn layout_table_order_matches_baked_groups() {
        // LAYOUTS[i] is xkb group i. This count MUST equal the number of comma-separated
        // entries in XKB_DEFAULT_LAYOUT in kimage/build/build-rootfs-browser.sh.
        assert_eq!(LAYOUTS.len(), 8);
        assert_eq!(LAYOUTS[0].1, "us"); // group 0 is the fallback
    }

    #[test]
    fn group_index_known_and_unknown() {
        assert_eq!(group_index("com.apple.keylayout.US"), 0);
        assert_eq!(group_index("com.apple.keylayout.Russian"), 1);
        assert_eq!(group_index("com.apple.keylayout.German"), 2);
        assert_eq!(group_index("com.apple.keylayout.Nonexistent"), 0); // unknown -> us
    }

    #[test]
    fn cycle_count_wraps() {
        assert_eq!(cycle_count(0, 3, 8), 3);
        assert_eq!(cycle_count(3, 3, 8), 0);
        assert_eq!(cycle_count(7, 1, 8), 2); // wrap forward: 7 -> 0 -> 1
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cargo test -p ignition-spike --bin boot layout_table_order_matches_baked_groups group_index_known_and_unknown cycle_count_wraps`
Expected: FAIL — `cannot find value LAYOUTS` / `cannot find function group_index` / `cycle_count`.

- [ ] **Step 3: Add the table + helpers**

Near the top of `spike/src/bin/display_sink.rs` (after `map_keycode`), add:

```rust
/// (macOS Text Input Source id, xkb layout name). The array index is the xkb GROUP index;
/// this order MUST match `XKB_DEFAULT_LAYOUT` in kimage/build/build-rootfs-browser.sh.
/// Group 0 is `us` and is the fallback for any unrecognised macOS layout.
pub const LAYOUTS: &[(&str, &str)] = &[
    ("com.apple.keylayout.US", "us"),
    ("com.apple.keylayout.Russian", "ru"),
    ("com.apple.keylayout.German", "de"),
    ("com.apple.keylayout.French", "fr"),
    ("com.apple.keylayout.Spanish", "es"),
    ("com.apple.keylayout.Italian", "it"),
    ("com.apple.keylayout.Ukrainian", "ua"),
    ("com.apple.keylayout.Polish", "pl"),
];

/// macOS input-source id -> xkb group index (0 = us fallback for anything unknown).
pub fn group_index(source_id: &str) -> usize {
    LAYOUTS.iter().position(|(id, _)| *id == source_id).unwrap_or(0)
}

/// Number of "next group" presses to advance from `current` to `target`, wrapping over `n` groups.
pub fn cycle_count(current: usize, target: usize, n: usize) -> usize {
    (target + n - current % n) % n
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cargo test -p ignition-spike --bin boot layout_table_order_matches_baked_groups group_index_known_and_unknown cycle_count_wraps`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add spike/src/bin/display_sink.rs
git commit -m "display_sink: LAYOUTS table + group_index/cycle_count helpers (intl layouts)"
```

---

### Task 2: macOS current-layout reader (Carbon TIS)

Read the current macOS keyboard layout id and resolve it to a group index. FFI to the Carbon Text Input Sources API; not unit-testable deterministically (depends on the machine's live layout), so verified by a build + a tiny manual print.

**Files:**
- Modify: `spike/Cargo.toml`
- Modify: `spike/src/bin/display_sink.rs`

- [ ] **Step 1: Add the core-foundation dependency**

In `spike/Cargo.toml`, under `[dependencies]`, add:

```toml
core-foundation = "0.10"
```

- [ ] **Step 2: Add the TIS reader**

In `spike/src/bin/display_sink.rs`, after the `group_index` function, add:

```rust
/// Read the current macOS keyboard layout's input-source id (e.g. "com.apple.keylayout.Russian")
/// via the Carbon Text Input Sources API. Returns None if it can't be read.
#[cfg(target_os = "macos")]
fn current_source_id() -> Option<String> {
    use core_foundation::base::{CFRelease, TCFType};
    use core_foundation::string::{CFString, CFStringRef};
    use std::os::raw::c_void;
    type TISInputSourceRef = *mut c_void;
    #[link(name = "Carbon", kind = "framework")]
    extern "C" {
        fn TISCopyCurrentKeyboardInputSource() -> TISInputSourceRef; // +1 ref (must release)
        fn TISGetInputSourceProperty(src: TISInputSourceRef, key: CFStringRef) -> *const c_void; // get-rule
        static kTISPropertyInputSourceID: CFStringRef;
    }
    unsafe {
        let src = TISCopyCurrentKeyboardInputSource();
        if src.is_null() {
            return None;
        }
        let val = TISGetInputSourceProperty(src, kTISPropertyInputSourceID);
        let out = if val.is_null() {
            None
        } else {
            Some(CFString::wrap_under_get_rule(val as CFStringRef).to_string())
        };
        CFRelease(src as *const c_void);
        out
    }
}

/// The xkb group index that matches the current macOS layout (0 = us fallback).
#[cfg(target_os = "macos")]
fn current_macos_group() -> usize {
    current_source_id().map(|id| group_index(&id)).unwrap_or(0)
}
```

- [ ] **Step 3: Build to verify it compiles + links Carbon**

Run: `cargo build -p ignition-spike --bin boot`
Expected: `Finished` with no link errors (Carbon framework + core-foundation resolve).

- [ ] **Step 4: Manual sanity (optional, fast)**

Temporarily add `eprintln!("[layout] group={} id={:?}", current_macos_group(), current_source_id());` at the top of `fn main()`, `cargo run -p ignition-spike --bin boot -- --help 2>&1 | grep layout` won't run main; instead run the existing dev harness or just trust the build. Remove the temp line before committing. (Deterministic verification is the manual HVF test in Task 5.)

- [ ] **Step 5: Commit**

```bash
git add spike/Cargo.toml spike/src/bin/display_sink.rs Cargo.lock
git commit -m "display_sink: read current macOS layout via Carbon TIS -> xkb group"
```

---

### Task 3: Sync the guest group on each key press

Add `guest_group` state to `App`, a `sync_group` method that injects Scroll Lock cycles, and call it before forwarding a key press.

**Files:**
- Modify: `spike/src/bin/display_sink.rs`

- [ ] **Step 1: Add the guest_group field**

Read the `struct App { … }` definition (around line 188). Add a field alongside `modifiers`:

```rust
    /// Host-side model of the guest's active xkb group (cage starts at 0 on every fresh
    /// restore; a session restore is a fresh boot process so this resets to 0 automatically).
    guest_group: usize,
```

Then find where `App` is constructed/initialized (the place that sets `modifiers: winit::keyboard::ModifiersState::empty(),`, around line 495) and add `guest_group: 0,` next to it.

- [ ] **Step 2: Add a Scroll Lock constant + the sync method**

Add near `map_keycode` (top of file):

```rust
/// Linux evdev KEY_SCROLLLOCK. cage binds it to "advance xkb group" via grp:sclk_toggle.
const KEY_SCROLLLOCK: u16 = 70;
```

Add an `impl App` method (inside the existing `impl App` block, near the keyboard handling):

```rust
    /// Make the guest's active xkb group match the current macOS layout by injecting
    /// `KEY_SCROLLLOCK` presses (each advances one group). No-op on non-macOS or when
    /// already aligned. Best-effort: a failed inject just leaves the group as-is.
    #[cfg(target_os = "macos")]
    fn sync_group(&mut self) {
        use ignition_devices::virtio::input::InputEvent;
        let Some(kbd) = &self.keyboard else { return };
        let target = current_macos_group();
        let n = LAYOUTS.len();
        for _ in 0..cycle_count(self.guest_group, target, n) {
            let evs = [
                InputEvent { etype: 1, code: KEY_SCROLLLOCK, value: 1 }, // press
                InputEvent { etype: 0, code: 0, value: 0 },             // SYN
                InputEvent { etype: 1, code: KEY_SCROLLLOCK, value: 0 }, // release
                InputEvent { etype: 0, code: 0, value: 0 },             // SYN
            ];
            let _ = kbd.lock().unwrap_or_else(|p| p.into_inner()).inject_input(&evs);
        }
        self.guest_group = target;
    }

    #[cfg(not(target_os = "macos"))]
    fn sync_group(&mut self) {}
```

- [ ] **Step 3: Call sync_group before forwarding a key press**

In the `WindowEvent::KeyboardInput` arm, in the block that maps and injects the scancode (the `if let PhysicalKey::Code(kc) = event.physical_key && let (Some(code), Some(kbd)) = (map_keycode(kc), &self.keyboard)` block), call `sync_group()` only on a press, **before** building/injecting the key events. Because `sync_group` borrows `self` mutably and the existing block borrows `self.keyboard`, restructure so the sync happens first:

```rust
                if let PhysicalKey::Code(kc) = event.physical_key {
                    if event.state.is_pressed() {
                        self.sync_group();
                    }
                    if let (Some(code), Some(kbd)) = (map_keycode(kc), &self.keyboard) {
                        let value = if event.state.is_pressed() { 1 } else { 0 };
                        let evs = [
                            InputEvent { etype: 1, code, value },       // EV_KEY
                            InputEvent { etype: 0, code: 0, value: 0 }, // EV_SYN/SYN_REPORT
                        ];
                        let _ = kbd.lock().unwrap_or_else(|p| p.into_inner()).inject_input(&evs);
                    }
                }
```

(The hotkey-intercept block just above this is unchanged — host `⌃⌥` chords still return early before this.)

- [ ] **Step 4: Build + run the existing tests**

Run: `cargo build -p ignition-spike --bin boot && cargo test -p ignition-spike --bin boot`
Expected: builds; all tests (hotkey + the Task 1 helpers) pass.

- [ ] **Step 5: Commit**

```bash
git add spike/src/bin/display_sink.rs
git commit -m "display_sink: sync guest xkb group to macOS layout before each key press"
```

---

### Task 4: Bake the superset keymap into the guest rootfs

**Files:**
- Modify: `kimage/build/build-rootfs-browser.sh`

- [ ] **Step 1: Set the multi-group xkb env in the cage-kiosk service**

In `kimage/build/build-rootfs-browser.sh`, find the `cage-kiosk` openrc service heredoc — it exports `XKB_DEFAULT_LAYOUT=us`. Replace that line with the superset + group-cycle option:

```sh
export XKB_DEFAULT_LAYOUT="us,ru,de,fr,es,it,ua,pl"
export XKB_DEFAULT_OPTIONS="grp:sclk_toggle"
```

> The comma-separated order MUST match `LAYOUTS` in `spike/src/bin/display_sink.rs` (8 entries: us, ru, de, fr, es, it, ua, pl). `grp:sclk_toggle` makes Scroll Lock advance the active group; the host (`sync_group`) is the only thing that presses it. No `grp_led` option — the guest has no Scroll Lock LED.

- [ ] **Step 2: Syntax-check**

Run: `bash -n kimage/build/build-rootfs-browser.sh && echo ok`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add kimage/build/build-rootfs-browser.sh
git commit -m "browser rootfs: bake us,ru,de,fr,es,it,ua,pl xkb groups + Scroll Lock cycle"
```

---

### Task 5: Build, rebuild rootfs, end-to-end HVF test

Not unit-testable — verify on real hardware.

- [ ] **Step 1: Build boot**

Run: `cargo build -p ignition-spike --bin boot`
Expected: `Finished`.

- [ ] **Step 2: Rebuild the rootfs (Docker) + the browser-base snapshot**

The rootfs builds in arm64 Docker (on artemis2 or any Docker host): `kimage/build/build-rootfs-browser.sh` → `~/kbuild/out/rootfs-browser.ext4`. Then rebuild `browser-base` (the app's first-run rebuilds it once the new rootfs is in place, since the guest-stamp changes).

- [ ] **Step 3: Manual layout test**

Launch a session (`boot --gui --restore browser-base …` or via the app). In the guest Firefox address bar:
1. macOS layout = **U.S.** → type `hello` → `hello`.
2. Switch macOS to **Russian** → type the same physical keys → Cyrillic (`привет`-style mapping) appears.
3. Switch macOS to **German** mid-typing → subsequent keys use the German layout (e.g. `z`/`y` swapped, `ß`).
4. Switch back to **U.S.** → Latin again.
5. Confirm `⌃⌥R` / `⌃⌥S` / `⌃⌥X` host hotkeys still work and `Enter`/`Backspace`/arrows are unaffected.

- [ ] **Step 4: Commit any fixups, then this is ready to ship** via the normal ignition-pin bump + guest-asset republish (see the auto-update pipeline).

---

## Self-Review

**Spec coverage:**
- Baked superset keymap + Scroll Lock cycle (spec §1) → Task 4. ✓
- `LAYOUTS` table = single source of truth, order matches rootfs (spec §1/§2) → Task 1 (+ integrity test) and Task 4 (matching list + cross-ref comment). ✓
- macOS layout read via TIS, unknown → group 0 (spec §2 / error handling) → Task 2 (`current_macos_group`, `group_index` fallback). ✓
- `guest_group` state + `sync_group` cycling before each press (spec §2) → Task 3. ✓
- Poll-on-keypress, no observer (spec decisions) → Task 3 Step 3 (call in KeyboardInput). ✓
- Snapshot restore resets group to 0 (spec §3) → automatic (fresh process per restore); noted in Task 3 Step 1 comment. ✓
- Modifiers/shortcuts unaffected (spec edge cases) → Task 3 Step 3 leaves the hotkey block and release path untouched; `sync_group` runs only on press. ✓
- Testing: cycle math + table integrity unit tests (Task 1); compile/link (Task 2); manual HVF (Task 5) — matches spec Testing. ✓

**Placeholder scan:** No TBD/TODO. The one "optional manual sanity" (Task 2 Step 4) is explicitly optional and removable; all code steps show complete code.

**Type/name consistency:** `LAYOUTS`, `group_index`, `cycle_count`, `current_source_id`, `current_macos_group`, `sync_group`, `guest_group`, `KEY_SCROLLLOCK` — used consistently across Tasks 1–3. `cycle_count(current, target, n)` signature matches its call in `sync_group`. `LAYOUTS.len() == 8` matches the 8-entry `XKB_DEFAULT_LAYOUT` in Task 4.
