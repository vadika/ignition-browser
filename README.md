# Ignition Browser

A menu-bar macOS app (Apple Silicon) that opens a URL in a throwaway microVM browser.
Each session is a short-lived Firefox running inside an [ignition](vendor/ignition)
microVM; close the window and the VM and its disk clone are destroyed. Nothing the page
does survives.

## Architecture

- The app is a menu-bar agent (no Dock icon). It registers a macOS **Service**
  ("Open in Ignition Browser") so you can send a selected URL from any app.
- For each session it spawns **gvproxy** (gvisor-tap-vsock, user-mode networking) and
  **`boot --gui`** from `vendor/ignition`. boot owns its own window; networking is the
  qemu `-netdev socket` protocol over a unix socket shared with gvproxy.
- **Ephemeral / fork-per-session:** restore a CoW child from the `browser-base` warm
  snapshot, run it, then destroy the child + delete its clonefile clone on window close.
  Orphaned clones from a prior crash are swept on launch.
- The validated URL is injected into the guest over a **typed vsock channel** (never a
  shell), where a guest-side listener opens Firefox.

## Prereqs

1. **Build boot** from the pinned ignition submodule:
   ```
   scripts/build-boot.sh        # needs DEV_ID for signing; cargo build is the core step
   ```
2. **Build the `browser-base` snapshot** (one time):
   ```
   vendor/ignition/scripts/make-browser-base.sh
   ```
   > TODO: that script currently uses socket_vmnet (`--net`). This app instead gives
   > each child gvproxy networking, so the warm snapshot should be built **without**
   > net and children get gvproxy at restore time. Reconcile this.

## Dev run

```
swift run IgnitionBrowser
```
Resolves boot/kernel from `vendor/ignition` (dev fallback in `Config.swift`).

## Build the .app

```
scripts/build-app.sh             # assembles + deep-signs dist/IgnitionBrowser.app
scripts/notarize.sh              # notarize + staple
```

## Status: scaffold / M0-in-progress

**Works**
- Menu-bar app + "New Ignition Browser" / Quit menu.
- macOS Services registration ("Open in Ignition Browser").
- URL validation/normalization (http/https only; rejects javascript:/file:/ftp:/empty).
- Spawn-boot glue: builds the correct `boot --gui --restore … --net-socket …` argv
  (array, never a shell), session bookkeeping, termination-handler teardown,
  orphan sweep.

**Stubbed (see `// TODO(Mx):` in source)**
- gvproxy spawn + RFC1918/host-LAN egress filter (M3).
- URL injection over vsock to the guest Firefox listener (M1/M4; guest listener lands in
  ignition's browser rootfs).
- Warm-parent re-warm optimization (M2).
- First-run setup: rootfs download + integrity check, local snapshot warm with progress (M5).
- Notarization secrets, Sparkle appcast/EdDSA signing (M6 / release.yml).

See [DECISIONS.md](DECISIONS.md) for the full rationale and the open/deferred list.
