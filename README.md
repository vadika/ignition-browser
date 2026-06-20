# 🔥 Ignition Browser

Open risky links in a browser that throws itself away.

Ignition Browser is a tiny menu-bar app for Apple Silicon Macs. Every link you open spins
up a fresh **Firefox inside its own hardware microVM**. Close the window and the whole
thing — disk, cookies, history, whatever the page did — is destroyed. The next link gets a
brand-new machine. Nothing persists, nothing touches your Mac.

→ [vadika.github.io/ignition-browser](https://vadika.github.io/ignition-browser)

## Install

1. Download **IgnitionBrowser.app.zip** from the [latest release](https://github.com/vadika/ignition-browser/releases/latest).
2. Unzip it and drag `IgnitionBrowser.app` to `/Applications`.
3. Open it. The first launch builds a one-time warm snapshot (~30s); after that, sessions
   start in a couple of seconds.

Signed and notarized. It keeps itself up to date automatically (Sparkle).

**Requires:** Apple Silicon Mac, macOS 15+, ~1 GB free disk (for the guest image, built once).

## Use it

A flame icon 🔥 sits in your menu bar. From there:

- **New Ignition Browser** — a fresh blank session.
- **Open URL…** (`⌃⌥I` from anywhere) — type or paste a URL into a quick panel.
- **Open Clipboard URL** — open whatever link you just copied.

Or from **any app**: select a link → right-click → **Services → Open in Ignition Browser**.

Inside a session, your usual Firefox shortcuts work (address bar, reload, find, zoom…).
Host keys use `⌃⌥`:

| Shortcut | Action |
|----------|--------|
| `⌃⌥R` | Reset — fresh session |
| `⌃⌥S` | Snapshot the VM |
| `⌃⌥X` | Close the session |

Close the window and the VM is gone.

## How it works

- Each session is a real VM on Apple's **Hypervisor.framework**, restored from a warm
  snapshot — restore is milliseconds, and the page is on screen in ~2–3s.
- Networking is **user-mode NAT only** ([gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock)):
  the guest reaches the public internet but **can't see your machine or your LAN**.
- The URL is handed to the guest over a typed **vsock** channel (never a shell), where
  Firefox navigates to it.
- The microVM runtime is [ignition](https://github.com/vadika/ignition).

## Build from source

```bash
export DEV_ID='Developer ID Application: Your Name (TEAMID)'
scripts/build-boot.sh        # build + sign the ignition boot binary (from the submodule)
scripts/build-gvproxy.sh     # build the egress-filtered gvproxy
scripts/build-app.sh         # assemble + deep-sign dist/IgnitionBrowser.app
scripts/notarize.sh          # notarize + staple
```

For a quick dev run (resolves boot/kernel from `vendor/ignition`):

```bash
swift run IgnitionBrowser
```

Releases are cut by tagging `vX.Y.Z` (CI builds, notarizes, signs the Sparkle appcast).
See [DECISIONS.md](DECISIONS.md) for the design rationale.

## License

© 2026 Vadim Likholetov. Built on [ignition](https://github.com/vadika/ignition) (Apache-2.0).
Bundles Firefox ESR (MPL-2.0), Alpine, cage/wlroots/Mesa, and Linux — see the
[site footer](https://vadika.github.io/ignition-browser) for full attributions. Firefox is a
Mozilla Foundation trademark; this project is not affiliated with Mozilla or Apple.
