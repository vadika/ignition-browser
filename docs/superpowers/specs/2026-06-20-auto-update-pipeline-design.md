# Auto-update pipeline — design

Date: 2026-06-20

## Goal

Keep Ignition Browser current with Firefox and deliver updates to installed apps with **zero
human touch**: when Alpine ships a new `firefox-esr`, the rootfs is rebuilt, a new app version
is released, and every installed app self-updates via Sparkle.

## Pipeline overview

```
[GH cron] check Alpine firefox-esr version ──changed?──▶ [artemis2 self-hosted runner]
   rebuild rootfs → publish assets to registry (:latest) → bump app version (patch++) → tag vX
        │
        ▼
[release.yml on tag vX] build/notarize .app → EdDSA-sign the .zip → append item to
   docs/appcast.xml (commit to main; GitHub Pages serves it)
        │
        ▼
[installed apps] Sparkle background-checks the appcast → auto-download + silent install
```

Trigger source: **Alpine 3.19 community `firefox-esr` package version** (what the rootfs actually
installs), not Mozilla upstream. Release gating: **fully automatic** (no approval step).

## Components

### 1. Sparkle updater (in-app)

- **Dependency:** add Sparkle (https://github.com/sparkle-project/Sparkle, 2.x) to `Package.swift`
  as a SwiftPM dependency of the `IgnitionBrowser` target. (Replaces the `TODO(M6)` comment.)
- **`Sources/IgnitionBrowser/AppDelegate.swift`:** own an `SPUStandardUpdaterController`
  (started automatically, `startingUpdater: true`), created in `applicationDidFinishLaunching`.
  Add a **"Check for Updates…"** menu item (above the version row) wired to
  `updaterController.checkForUpdates(_:)`.
- **`Resources/Info.plist`:**
  - `SUFeedURL` = `https://vadika.github.io/ignition-browser/appcast.xml`
  - `SUPublicEDKey` = `<base64 EdDSA public key>`
  - `SUEnableAutomaticChecks` = `true`
  - `SUAutomaticallyUpdate` = `true` (download + install silently, matching the fully-automatic goal)
  - `SUScheduledCheckInterval` = `86400` (daily)
- **`scripts/build-app.sh`:** copy `Sparkle.framework` into `Contents/Frameworks/`, deep-sign it
  **inner-first** (its `XPCServices/*.xpc`, `Autoupdate`, `Updater.app`, then the framework) with
  Developer ID + hardened runtime + timestamp, before the outer app signature. SwiftPM resolves
  Sparkle into `.build`; the script copies the built `.framework` from there.

### 2. Appcast + signing (`.github/workflows/release.yml`)

- **One-time:** generate an EdDSA keypair with Sparkle's `generate_keys`. Public key → `Info.plist`
  `SUPublicEDKey`. Private key → repo secret `SPARKLE_ED_PRIVATE_KEY`.
- **In release.yml, after notarize + staple, before/with the GH-release upload:**
  1. `sign_update dist/IgnitionBrowser.app.zip` (private key from the secret) → EdDSA signature + length.
  2. Prepend a new `<item>` to `docs/appcast.xml`: `<title>`, `sparkle:version` (CFBundleVersion),
     `sparkle:shortVersionString`, `<enclosure url=…>` pointing at the GitHub release asset
     (`…/releases/download/vX.Y.Z/IgnitionBrowser.app.zip`), `sparkle:edSignature`, `length`,
     `<pubDate>`, `<sparkle:minimumSystemVersion>14.0`.
  3. Commit `docs/appcast.xml` to `main` (`git push`), so GitHub Pages serves the updated feed.
- Appcast file lives at `docs/appcast.xml` (GitHub Pages root is `docs/`).

### 3. Firefox watcher (`.github/workflows/firefox-watch.yml`)

- **Trigger:** `schedule` (daily cron) + `workflow_dispatch` (manual / forced version for testing).
- **Runner:** GH-hosted `ubuntu-latest`.
- **Steps:**
  1. Read current Alpine 3.19 community `firefox-esr` version — run `docker run --rm alpine:3.19
     sh -c "apk update -q && apk policy firefox-esr | sed -n '2p'"` (or query the Alpine package
     API), extract the version string.
  2. Compare to the tracked `.firefox-esr-version` file in the repo root.
  3. **Unchanged →** exit 0 (no-op). **Changed →** emit the new version as a job **output**
     (`changed=true`, `version=…`); the rebuild job (`needs:` this one, same workflow file, gated on
     `changed == 'true'`) consumes it. The watcher does **not** commit — the rebuild job writes
     `.firefox-esr-version` together with the version bump in one commit (§4), avoiding two commits / a race.

### 4. Rebuild + release job (self-hosted on artemis2)

- **Runner:** `runs-on: [self-hosted, artemis2]` (registered GH Actions runner on artemis2 with
  Docker + access to the local registry).
- **Guard:** the job runs **only** on `schedule`/`workflow_dispatch` from the watcher on the default
  branch — never on `pull_request`. (Self-hosted runner on a public repo must not execute untrusted
  PR code; enforce via `if: github.event_name != 'pull_request'` and repo runner-group settings.)
- **Steps:**
  1. `kimage/build/build-rootfs-browser.sh` → `~/kbuild/out/rootfs-browser.ext4`.
  2. `scripts/publish-guest-assets.sh` → `oras push` `:latest` + the ignition short-SHA tag.
  3. Write the new Firefox version to `.firefox-esr-version` and bump `Resources/Info.plist`
     `CFBundleShortVersionString` **patch++** (0.0.N → 0.0.N+1) and `CFBundleVersion` — one commit.
  4. `git tag vX.Y.Z`, `git push origin main --tags` → triggers `release.yml`.

## Data flow

```
cron ─▶ firefox-watch (ubuntu): Alpine firefox-esr version
     ─changed─▶ rebuild job (artemis2): build rootfs ─▶ publish :latest ─▶ patch++ ─▶ tag vX
     ─tag─▶ release.yml (macos): build+notarize .app ─▶ sign_update ─▶ append appcast ─▶ push docs/
     ─Pages─▶ Sparkle (installed apps): fetch appcast ─▶ verify EdDSA ─▶ download ─▶ silent install
```

## Error handling

- Any build/publish step fails → no tag is pushed → no release → installed apps stay on the last
  working version (safe no-op).
- Sparkle verifies the EdDSA signature against `SUPublicEDKey`; a bad/missing signature → the update
  is rejected client-side (no install).
- Watcher is idempotent: `.firefox-esr-version` gates duplicate triggers, so a re-run without a real
  Alpine change does nothing.
- release.yml appcast commit uses the release tag as the source of truth; a failed appcast push does
  not unpublish the release (the asset is already up) — re-running the appcast step is safe (prepend
  is keyed by version; skip if the item already exists).

## Testing

- **Sparkle (manual):** point `SUFeedURL` at a local/test appcast, sign a throwaway build with a test
  keypair, confirm "Check for Updates…" finds + installs it. Verify a tampered `.zip` is rejected.
- **Watcher:** `workflow_dispatch` with a forced version input → confirms the change path dispatches
  the rebuild; run again unchanged → confirms no-op.
- **Rebuild job:** rootfs build + publish path is already proven (used this session); the new bits are
  the version bump + tag, verifiable by a dry-run that stops before `git push`.
- **End-to-end:** one full cron cycle on a real Alpine `firefox-esr` bump (or a forced dispatch)
  produces a new release and an installed app auto-updates.

## Decisions

- Updater: **Sparkle 2.x**; silent auto-install (`SUAutomaticallyUpdate=true`).
- Appcast hosted on **GitHub Pages** at `docs/appcast.xml`.
- Trigger: **Alpine 3.19 community `firefox-esr`** package version (tracked in `.firefox-esr-version`).
- Version bump: **patch** per Firefox change.
- Rebuild runs on a **self-hosted runner on artemis2**; release gating is **fully automatic**.

## Out of scope (YAGNI)

- Pinning `firefox-esr=<version>` in the rootfs (watcher uses Alpine's current version directly).
- Update channels / betas, rollback UI, delta updates, release notes authoring (appcast item gets a
  generated title; rich notes can come later).
- Mozilla-upstream watching, Homebrew cask.
