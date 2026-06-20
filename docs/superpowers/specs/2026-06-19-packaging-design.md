# ignition-browser packaging — design

_Design spec. Status: approved in brainstorming, awaiting implementation plan._

## Goal

Ship a **runnable, notarized `.app`**: a user downloads it, double-clicks, completes a
one-time first-run setup with visible progress, and then "Open in Ignition Browser"
(Services) / "New Ignition Browser" (menu) opens a disposable Firefox microVM that loads
a page — with no Terminal, Homebrew, sudo, or manual config, on a clean second Mac.

Scope = the M5 acceptance core. **Sparkle auto-update is deferred** (only matters once a
shipping build exists to update). Asset hosting / download-on-first-run is deferred
(bundle everything for now — no hosting infra to set up).

## Decisions (settled in brainstorming)

- **Bundle all runtime assets in the `.app`.** `boot`, `gvproxy` (egress-filtered), kernel
  `Image` raw + Developer-ID signed; the guest rootfs **gzip-compressed**
  (`rootfs-browser.ext4.gz`) because it is mostly sparse (~1.5G ext4 → ~400–500M). No
  hosting, no download code, works offline.
- **Decompress with native `gunzip`** (`/usr/bin/gunzip`, always present) — no zstd binary
  to bundle. The rootfs is decompressed to a **temp file**, consumed by the first-run base
  build, then deleted; the `browser-base` snapshot's own `disk.img` is the working copy.
- **First-run base build in Swift, snapshot via the control socket** (not make-browser-base.sh's
  FIFO/Ctrl-A keystroke hack): spawn `boot --gui … --control-sock` and send
  `{"action":"snapshot","name":"browser-base"}` over the control channel on `BROWSER_READY`.
- **Notarize via the App Store Connect API key** (`--key/--key-id/--issuer`) in CI, not a
  keychain profile.

## Non-goals (this pass)

- Sparkle auto-update (SPM dep, updater, appcast generation/signing/hosting).
- Download-on-first-run + hosted, integrity-checked rootfs.
- Shrinking the snapshot's on-disk footprint (~3.5G in the app store after first-run).
- A code-signed installer / DMG (ship the notarized `.app` zip).

## Architecture

```
.app/Contents/
  MacOS/IgnitionBrowser              (the Swift binary)
  Info.plist                         (LSUIElement agent + NSServices)
  Resources/
    boot           raw, Developer-ID signed
    gvproxy        raw, Developer-ID signed (egress-filtered build)
    Image          raw (kernel)
    rootfs-browser.ext4.gz           gzip-compressed guest rootfs
    IgnitionBrowser.entitlements     (com.apple.security.hypervisor)

first run (no browser-base in store):
  gunzip rootfs.gz -> $TMPDIR/rootfs-browser.ext4
  spawn gvproxy (filtered)               [build-time net so the base has a net device]
  spawn boot --gui --net --net-socket <gv> --vsock-uds <u> --control-sock <c>
            --store <appstore> --name browser-base <Image> <temp rootfs>
  read boot stdout until BROWSER_READY
  control <c>: {"action":"snapshot","name":"browser-base"}   [reuses FC-REST control listener]
  wait for snapshot write, kill boot + gvproxy, rm temp rootfs

steady state (SessionManager, unchanged):
  per session: spawn gvproxy + boot --gui --restore browser-base --net --net-socket
            --vsock-uds --store <appstore>; inject URL over vsock 7777
```

## Components

### a. Config (modify)
Add `rootfsArchive: URL` (bundled `Resources/rootfs-browser.ext4.gz`) and `rootfsImage: URL`
(the decompress target, e.g. a temp path) — first-run needs the rootfs; steady-state restore
does not (the snapshot carries it). Bundled branch points at `Resources/`; dev branch keeps
the existing `vendor/ignition` fallbacks (dev decompresses the repo's `kimage/out/rootfs-browser.ext4`
or uses it directly).

### b. FirstRun (new, `Sources/IgnitionBrowser/FirstRun.swift`)
- `static func isComplete(_ config) -> Bool`: `<store>/snapshots/browser-base` exists.
- `static func run(_ config, progress:) throws`: disk-space preflight (≥4 GiB free in the
  store volume, else throw a clear error); gunzip the bundled archive to a temp file (skip if
  dev already has a raw rootfs); spawn the filtered gvproxy; spawn `boot --gui … --control-sock`;
  read boot's stdout line-by-line until `BROWSER_READY` (with a timeout → error); send the
  control snapshot command; poll until `<store>/snapshots/browser-base/manifest.json` exists;
  terminate boot + gvproxy; delete the temp rootfs.
- A tiny control-socket client (line-JSON `{"action":"snapshot","name":…}` → read `{"ok":true}`),
  sibling of `VsockClient`. May be the same helper generalized, or a 15-line local fn.

### c. AppDelegate (modify)
Replace the `TODO(M5)` with: on `applicationDidFinishLaunching`, if `!FirstRun.isComplete`,
present a SwiftUI/AppKit progress window ("Preparing Ignition Browser… one-time, ~30–60s"),
run `FirstRun.run` on a background thread, dismiss on success (or show the error). The boot
`--gui` warm-up window is itself visible progress. Only after first-run completes do the menu /
Services actions become live (or they trigger first-run if invoked early).

### d. build-app.sh (complete the TODOs)
After `swift build -c release`: assemble the bundle; copy `boot`, `gvproxy`, `Image` into
Resources; `gzip -c kimage…/rootfs-browser.ext4 > Resources/rootfs-browser.ext4.gz`; deep-sign
`boot` and `gvproxy` (`--options runtime --timestamp`); sign the app with the entitlements.
Depends on `build-boot.sh` (boot) and `build-gvproxy.sh` (filtered gvproxy) having run.

### e. notarize.sh (already complete)
ditto-zip → `notarytool submit --wait` → `stapler staple`. Switch the credential to the API
key form for CI (keep keychain-profile for local).

### f. release.yml (complete the secret wiring)
Import `DEVELOPER_ID_CERT_P12` (base64) into a temp keychain, unlock, set `DEV_ID` from the
identity; run build-boot → build-gvproxy → build-app; notarize with
`NOTARY_API_KEY`/`ISSUER`/`KEY_ID`; upload the stapled `.app` zip to the GitHub release. Drop
the Sparkle step.

## Error handling

- **Disk-space preflight** before first-run; clear error if < ~4 GiB free.
- **`BROWSER_READY` timeout** (e.g. 120 s) → first-run fails with a readable message + the
  captured boot tail; leave no half-built snapshot (delete a partial `browser-base`).
- **gunzip / spawn failures** → surface in the progress window; cleanup temp rootfs.
- **Missing `DEV_ID` / notary creds** → scripts already fail fast with a hint.
- First-run is **idempotent**: re-running when `browser-base` exists is a no-op
  (`isComplete` short-circuits); a failed/partial run cleans up so the next launch retries.

## Testing

- **Unit (Swift):** `Config` resolves the bundled archive + image paths; `FirstRun.isComplete`
  true/false by snapshot presence (temp store dirs); the control-snapshot command framing
  (against a fake server, like `VsockClientTests`).
- **Script:** `bash -n` on build-app.sh / release.yml lint; a dry `build-app.sh` against
  prebuilt boot/gvproxy/kernel produces a bundle whose structure + `codesign --verify
  --deep --strict` pass (adhoc-signed locally when no `DEV_ID`).
- **Live (by hand, M-series HVF):** local `build-app.sh` (adhoc) → launch the `.app` → first-run
  builds `browser-base` with progress → "New Ignition Browser" opens Firefox; then the **real
  acceptance**: a Developer-ID notarized build from CI, copied to a **clean second Mac**, runs
  first-run and opens a disposable browser with no Terminal/sudo/Homebrew, and the guest cannot
  reach the host LAN.

## Files

- Modify: `Sources/IgnitionBrowser/Config.swift` (rootfs archive/image paths), `AppDelegate.swift`
  (first-run gate + progress), `scripts/build-app.sh` (gzip + copy + deep-sign), `scripts/notarize.sh`
  (API-key cred), `.github/workflows/release.yml` (secret wiring, drop Sparkle).
- Create: `Sources/IgnitionBrowser/FirstRun.swift`, `Tests/IgnitionBrowserTests/FirstRunTests.swift`.
- Reuse: `scripts/build-boot.sh`, `scripts/build-gvproxy.sh` (already present).
