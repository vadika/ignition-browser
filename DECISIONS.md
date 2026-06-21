# Decisions

Settled design decisions for the Ignition Browser MVP. Each line is the decision
plus a one-line rationale.

## Settled

- **Runtime: ignition (vendor/ignition submodule), Hypervisor.framework.** Do not
  reimplement the VM — ignition already boots microVMs on HVF.
- **v1 window model: spawn `boot --gui` as a subprocess.** boot owns its own winit
  NSWindow; native-SwiftUI-embedded framebuffer is more work and is deferred to v2.
- **Guest browser: Firefox.** ignition already builds a Firefox-kiosk base + a
  `browser-base` warm snapshot (vendor/ignition/scripts/make-browser-base.sh);
  Chromium dropped to avoid maintaining two guest stacks.
- **International input: keyboard layouts SHIPPED (v0.0.22), full IME deferred.** The guest
  follows the macOS keyboard layout (Cyrillic/German/etc.) via baked xkb groups + host-driven
  group switching (see "Shipped since the MVP"). Dead-key composition and CJK/IME are a later stage.
- **Networking: gvisor-tap-vsock (gvproxy), user-mode, unprivileged.** boot's existing
  `--net-socket <path>` speaks the qemu `-netdev socket` protocol (4-byte BE length +
  ethernet frame, no handshake), wire-compatible with gvproxy `-listen-qemu`, so no
  ignition change is needed — the app spawns gvproxy and hands its socket to boot.
  **VERIFIED 2026-06-18** (headless, `scripts/net-smoketest.sh`): `gvproxy -listen-qemu`
  + `boot --net --net-socket <sock>` complete a full DHCP DORA — guest leases
  `192.168.127.3`, gateway/DNS `192.168.127.1`. Zero ignition code touched. gvproxy
  installed via `go install github.com/containers/gvisor-tap-vsock/cmd/gvproxy@latest`.
  **Egress also verified end-to-end**: guest TCP-connects 1.1.1.1:80 and fetches
  `http://example.com` → HTTP 200 (DNS via gvproxy resolves, NAT works). gvproxy v0.8.9.
  **Operational note:** gvproxy is **single-client** — it exits when the qemu socket
  peer disconnects ("cannot read size from socket: EOF"). So the app spawns **one
  gvproxy per session child** (not one shared instance), torn down with the child.
- **Egress filter blocking RFC1918 / host-LAN — RESOLVED 2026-06-18.** Upstream gvproxy
  has no egress ACL (the Configuration `NAT`/`Forwards` fields are incoming-only), so we
  patch it: `patches/0001-egress-lan-filter.patch` adds `blockedEgress()` and a guard at
  the two outbound NAT chokepoints (`pkg/services/forwarder/{tcp,udp}.go`), mirroring the
  upstream link-local guard. It refuses to dial loopback / RFC1918 (10/8, 172.16/12,
  192.168/16) / IPv6 ULA (fc00::/7) / link-local / CGNAT (100.64/10) / unspecified —
  fail-closed on unparseable. Built by `scripts/build-gvproxy.sh` (clone pinned tag →
  apply patch → `go test TestBlockedEgress` → build → `dist/gvproxy`). **Verified live**:
  guest fetched `http://example.com` (public OK) but was refused `192.168.68.1` (host
  gateway), `192.168.68.104` (host IP), `10.0.0.1`, `192.168.1.1` — each logged
  `egress … refused`. gvproxy's own gateway/DNS (`192.168.127.1`) is internal (not via the
  forwarder), so DNS is unaffected. Unit test covers block-private / allow-public incl IPv6.
- **Entitlement: only `com.apple.security.hypervisor`.** Freely declarable; avoids the
  restricted com.apple.vm.* family.
- **Lifecycle: ephemeral.** One warm parent snapshot (browser-base); fork a CoW child
  per session; destroy child + delete its clonefile clone on window close; orphan-sweep
  on launch. Disposability is the product.
- **Repo: separate from ignition; ignition is a submodule at vendor/ignition.** boot is
  built from the pinned submodule in CI. VM-side scripts stay in ignition.
- **URL injection: typed channel, never shell interpolation.** Pasteboard text is
  attacker-controlled; validate/normalize host-side (http/https only), then write the
  URL over a vsock port to a guest-side listener that opens Firefox.
- **Packaging: SwiftPM executable + hand-rolled `.app` bundling script (no .xcodeproj).**
  Developer ID + hardened runtime + notarize + staple. **Sparkle auto-update — SHIPPED**
  (see the auto-update pipeline below).
- **Guest rootfs: bundled in the .app (gzipped), built once on first run.** The multi-GB
  rootfs ships as `Resources/rootfs-browser.ext4.gz` (download-on-first-run was dropped —
  the asset registry is private). First launch gunzips it and builds the host-bound
  `browser-base` warm snapshot locally with a progress window; a guest-asset fingerprint
  (`.guest-stamp`) rebuilds the base when the shipped assets or recipe change.

## Shipped since the MVP (2026-06-20)

- **URL intake surfaces (v0.0.16–v0.0.18).** Beyond the Services entry: a drop-under-the-
  menu-bar **entry panel** (global hotkey **`⌃⌥I`**, prefilled from the clipboard), an
  **Open Clipboard URL** menu item, and a version row. `⌥⌘I` was rejected — it clashes with
  terminal/browser inspectors.
- **Navigate the running Firefox via its DBus remote (v0.0.19).** Supersedes the
  kill-and-relaunch decision below. cage runs under `dbus-run-session`, so the kiosk-loop
  hands a new URL to the warm instance instead of cold-relaunching (~6s of Firefox startup
  saved). Marionette was tried and rejected (same speed once network was the gate, plus a
  persistent "remote control" address-bar tint).
- **Static network config on restore (v0.0.20).** The on-restore hook (and netwatch
  fallback) now assert `192.168.127.3/24`, gw/DNS `.1` statically instead of a ~5s `udhcpc`
  handshake that gated the first page load. Each session has its own isolated single-client
  gvproxy, so the deterministic `.3` never collides across concurrent VMs. Plus a 3s
  **settle** after `BROWSER_READY` before snapshot, so the warm base captures a fully-painted
  idle Firefox. Net result: opening a URL dropped from ~6.6s to ~3s (light page).
- **Auto-update pipeline (v0.0.21).** **Sparkle** updater (silent auto-install, appcast on
  GitHub Pages at `docs/appcast.xml`, EdDSA-signed in `release.yml`). A daily
  **`firefox-watch`** workflow compares Alpine's `firefox-esr` to `.firefox-esr-version`; on
  a bump, a **self-hosted runner on artemis2** rebuilds the rootfs, publishes assets, patch-
  bumps + tags, and `release.yml` ships it. Gotchas baked into the scripts: bundle+sign
  `Sparkle.framework` with an `@executable_path/../Frameworks` rpath; the rebuild job pushes
  the tag via a **deploy key** (GITHUB_TOKEN-pushed tags don't trigger workflows).
- **Resizable browser window (v0.0.23).** Dragging the `--gui` window edge re-modesets the guest
  (virtio-gpu connector-cycle) and the desktop reflows. Requires the new boot (drives the cycle,
  tablet range now fixed 0..32767) AND an Alpine 3.21 / cage 0.2.0 rootfs that survives the
  output disconnect — shipped together (submodule pin `2bc5272`, `baseRecipeVersion` 7 forces the
  warm-base re-create so the new tablet range is re-probed). Size clamps to [320×240, 1400×880].
- **International keyboard layouts (v0.0.22).** The guest keyboard follows the macOS layout.
  cage can't reload its xkb keymap at runtime, so the rootfs bakes a superset as xkb GROUPS
  (`XKB_DEFAULT_LAYOUT="us,ru,de,fr,es,it,ua,pl"`, `grp:sclk_toggle`); `boot`'s `display_sink`
  reads the live macOS layout (Carbon TIS) and, before each key press, injects Scroll Lock to
  advance the guest to the matching group. All in `firecracker-mac`; HVF-verified (Russian →
  Cyrillic). Layouts only — dead keys / IME are still deferred.

## Open / deferred

- **Native-window embedding (v2)** — embed the guest framebuffer in a SwiftUI window
  instead of letting boot own its winit NSWindow.
- **Full IME (dead keys / AltGr / CJK composition)** — keyboard *layouts* shipped (v0.0.22);
  composition input would need a Wayland virtual-keyboard text-injection path in the guest.
- **Clipboard sharing** — deferred unless explicitly requested (paste-in/copy-out
  between host and guest).
- **Warm-parent re-warm optimization** — keep a warm parent and re-warm after each
  claim; current model restores from browser-base directly per session.

## Live-proven (2026-06-19, M-series HVF)

Full runtime path verified end to end: a URL injected over vsock opens in Firefox in the
restored microVM, reaching the public internet through the filtered user-mode NAT.
- **Warm fork**: restore `browser-base` in ~16 ms (MAP_PRIVATE).
- **Net**: per-session filtered gvproxy; restored guest brings eth0 up statically (192.168.127.3,
  superseding the original netwatch re-DHCP) and runs live HTTPS to public IPs; host/LAN refused
  by the egress filter.
- **URL injection**: host `CONNECT 7777` → guest `open-url` writes `/run/openurl.target` →
  `kiosk-loop` navigates Firefox; example.com loaded in the GUI window.

Non-obvious base-build requirements discovered (encoded in `make-browser-base.sh`):
1. **Net device must be present in the snapshot.** A net-free base (`NET=0`) has no eth0 to
   restore — build the base over gvproxy (`NET_SOCKET=`) so the virtio-net device + a DHCP
   lease are captured; the netwatch poller re-DHCPs on restore.
2. **Vsock device must be present in the snapshot.** The base cold-boot must pass
   `--vsock-uds`, else the guest has no vsock device and the host can't reach ports 7777/9000.
3. **Navigate by relaunch, not remote.** *(Superseded in v0.0.19 — see "Shipped since the MVP".)*
   The original kiosk-loop ran ONE `--no-remote` Firefox and cold-relaunched it on each URL,
   because under cage there was no shared DBus session for a remote handoff. It now runs cage
   under `dbus-run-session` and navigates the warm instance via its DBus remote (no relaunch).
