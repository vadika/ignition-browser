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
- **IME / international input: deferred.** v1 uses raw keycodes via ignition's existing
  virtio-input; full IME is a later stage.
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
  Developer ID + hardened runtime + notarize + staple; Sparkle auto-update (stubbed).
- **Guest rootfs acquisition: download-on-first-run + integrity check.** Multi-GB rootfs
  keeps the .app small; first run also builds the host-bound warm snapshot locally with
  visible progress (TODO M5).

## Open / deferred

- **Native-window embedding (v2)** — embed the guest framebuffer in a SwiftUI window
  instead of letting boot own its winit NSWindow.
- **IME / international input** — later stage; v1 is raw keycodes only.
- **Clipboard sharing** — deferred unless explicitly requested (paste-in/copy-out
  between host and guest).
- **Warm-parent re-warm optimization** — keep a warm parent and re-warm after each
  claim; skeleton restores from browser-base directly per session.
- **Sparkle wiring** — appcast generation + EdDSA signing keys are stubbed.
- **Rootfs hosting location** — where the multi-GB rootfs + snapshot are downloaded
  from (and integrity manifest) is not yet decided.
- **make-browser-base.sh net reconciliation** — RESOLVED: `NET_SOCKET=<gvproxy>` builds the
  base over gvproxy (net device + lease present, no daemon); children get a fresh per-session
  gvproxy at restore.

## Live-proven (2026-06-19, M-series HVF)

Full runtime path verified end to end: a URL injected over vsock opens in Firefox in the
restored microVM, reaching the public internet through the filtered user-mode NAT.
- **Warm fork**: restore `browser-base` in ~16 ms (MAP_PRIVATE).
- **Net**: per-session filtered gvproxy; restored guest re-DHCPs (192.168.127.x via netwatch)
  and runs live HTTPS to public IPs; host/LAN refused by the egress filter.
- **URL injection**: host `CONNECT 7777` → guest `open-url` writes `/run/openurl.target` →
  `kiosk-loop` navigates Firefox; example.com loaded in the GUI window.

Non-obvious base-build requirements discovered (encoded in `make-browser-base.sh`):
1. **Net device must be present in the snapshot.** A net-free base (`NET=0`) has no eth0 to
   restore — build the base over gvproxy (`NET_SOCKET=`) so the virtio-net device + a DHCP
   lease are captured; the netwatch poller re-DHCPs on restore.
2. **Vsock device must be present in the snapshot.** The base cold-boot must pass
   `--vsock-uds`, else the guest has no vsock device and the host can't reach ports 7777/9000.
3. **Navigate by relaunch, not remote.** Under cage there is no shared DBus session, so a
   second `firefox-esr <url>` only hits the profile lock ("already running, not responding" →
   black screen). `kiosk-loop` runs ONE `--no-remote` instance and relaunches it on a new URL
   (tracking the real process via `pgrep`, since the firefox launcher pid exits immediately).
