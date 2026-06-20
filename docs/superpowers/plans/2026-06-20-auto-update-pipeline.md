# Auto-update Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Alpine ships a new `firefox-esr`, automatically rebuild the rootfs, cut a patch release, and have installed apps self-update via Sparkle — zero human touch.

**Architecture:** Two halves. (A) In-app **Sparkle** updater pointed at a GitHub-Pages appcast that `release.yml` signs+updates on every tag. (B) A scheduled **firefox-watch** workflow whose detect job (ubuntu) gates a rebuild job (self-hosted on artemis2) that rebuilds the rootfs, publishes assets, bumps the patch version, and tags — which fires `release.yml`. Pure logic (version bump, appcast item) is Python-`plistlib`/XML so it runs on macOS and Linux and is unit-tested; Swift/CI/bundling are build/dispatch-verified.

**Tech Stack:** Swift 6 + Sparkle 2.x (SwiftPM), GitHub Actions (hosted ubuntu + self-hosted artemis2), Python 3 stdlib (`plistlib`, `xml`), `codesign`/notarytool, `oras`/Tailscale (existing).

---

## File Structure

- Modify `Package.swift` — add Sparkle SwiftPM dependency.
- Modify `Sources/IgnitionBrowser/AppDelegate.swift` — `SPUStandardUpdaterController` + "Check for Updates…" menu item.
- Modify `Resources/Info.plist` — Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, auto-check/install).
- Modify `scripts/build-app.sh` — bundle + deep-sign `Sparkle.framework`.
- Create `scripts/bump_patch.py` — increment patch + CFBundleVersion in a plist (Linux+macOS). **Unit-tested.**
- Create `scripts/appcast_add.py` — prepend a signed `<item>` to the appcast. **Unit-tested.**
- Create `Tests/scripts/test_bump_patch.py`, `Tests/scripts/test_appcast_add.py` — pytest-free asserts (run with `python3`).
- Create `docs/appcast.xml` — initial empty Sparkle feed (served by Pages).
- Modify `.github/workflows/release.yml` — `sign_update` + appcast append + commit.
- Create `.firefox-esr-version` — tracked Alpine firefox-esr version.
- Create `.github/workflows/firefox-watch.yml` — detect job (ubuntu) + rebuild job (artemis2).
- Create `docs/superpowers/runbooks/artemis2-self-hosted-runner.md` — one-time runner setup.

Order: Tasks 1–5 ship the **updater** (independently releasable). Tasks 6–9 add the **automation**.

---

### Task 1: Version bump script (TDD)

Pure logic, runs on Linux (artemis2) and macOS. Uses `plistlib` (Python stdlib).

**Files:**
- Create: `scripts/bump_patch.py`
- Test: `Tests/scripts/test_bump_patch.py`

- [ ] **Step 1: Write the failing test**

Create `Tests/scripts/test_bump_patch.py`:

```python
import plistlib, subprocess, tempfile, os, sys

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "bump_patch.py")

def _plist(short, build=None):
    d = {"CFBundleShortVersionString": short}
    if build is not None:
        d["CFBundleVersion"] = build
    f = tempfile.NamedTemporaryFile(suffix=".plist", delete=False)
    plistlib.dump(d, f); f.close()
    return f.name

def run(path):
    out = subprocess.run([sys.executable, SCRIPT, path], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return out.stdout.strip()

def test_patch_increments_and_prints():
    p = _plist("0.0.20", "1")
    assert run(p) == "0.0.21"
    with open(p, "rb") as f: d = plistlib.load(f)
    assert d["CFBundleShortVersionString"] == "0.0.21"
    assert d["CFBundleVersion"] == "2"
    os.unlink(p)

def test_missing_build_defaults_to_1():
    p = _plist("1.2.3")
    assert run(p) == "1.2.4"
    with open(p, "rb") as f: d = plistlib.load(f)
    assert d["CFBundleVersion"] == "1"
    os.unlink(p)

if __name__ == "__main__":
    test_patch_increments_and_prints(); test_missing_build_defaults_to_1()
    print("OK")
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 Tests/scripts/test_bump_patch.py`
Expected: FAIL — `FileNotFoundError`/`No such file` for `scripts/bump_patch.py`.

- [ ] **Step 3: Write the script**

Create `scripts/bump_patch.py`:

```python
#!/usr/bin/env python3
"""Increment the patch of CFBundleShortVersionString in a plist, bump CFBundleVersion,
and print the new short version. Stdlib-only so it runs on the Linux artemis2 runner."""
import plistlib, sys

def main(path):
    with open(path, "rb") as f:
        d = plistlib.load(f)
    major, minor, patch = d["CFBundleShortVersionString"].split(".")
    new = f"{major}.{minor}.{int(patch) + 1}"
    d["CFBundleShortVersionString"] = new
    d["CFBundleVersion"] = str(int(d.get("CFBundleVersion", "0")) + 1)
    with open(path, "wb") as f:
        plistlib.dump(d, f)
    print(new)

if __name__ == "__main__":
    main(sys.argv[1])
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 Tests/scripts/test_bump_patch.py`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add scripts/bump_patch.py Tests/scripts/test_bump_patch.py
git commit -m "scripts: bump_patch.py (patch + build bump, plistlib) + tests"
```

---

### Task 2: Appcast item script (TDD)

Prepends one signed `<item>` to the Sparkle RSS feed. Stdlib `xml.dom.minidom`. Idempotent on version.

**Files:**
- Create: `scripts/appcast_add.py`
- Create: `docs/appcast.xml` (initial empty feed, also used by the test fixture)
- Test: `Tests/scripts/test_appcast_add.py`

- [ ] **Step 1: Create the initial appcast feed**

Create `docs/appcast.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Ignition Browser</title>
    <link>https://vadika.github.io/ignition-browser/appcast.xml</link>
    <description>Ignition Browser updates</description>
    <language>en</language>
  </channel>
</rss>
```

- [ ] **Step 2: Write the failing test**

Create `Tests/scripts/test_appcast_add.py`:

```python
import subprocess, tempfile, os, sys
from xml.dom import minidom

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "appcast_add.py")
SEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><title>Ignition Browser</title></channel>
</rss>"""

def seed():
    f = tempfile.NamedTemporaryFile(suffix=".xml", delete=False, mode="w")
    f.write(SEED); f.close(); return f.name

def add(path, ver, build, url, sig, length):
    r = subprocess.run([sys.executable, SCRIPT, path, ver, build, url, sig, length],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr

def test_item_added_with_fields():
    p = seed()
    add(p, "0.0.21", "2", "https://ex/IgnitionBrowser.app.zip", "SIGabc==", "12345")
    doc = minidom.parse(p)
    items = doc.getElementsByTagName("item")
    assert len(items) == 1
    enc = items[0].getElementsByTagName("enclosure")[0]
    assert enc.getAttribute("url") == "https://ex/IgnitionBrowser.app.zip"
    assert enc.getAttribute("sparkle:version") == "2"
    assert enc.getAttribute("sparkle:shortVersionString") == "0.0.21"
    assert enc.getAttribute("sparkle:edSignature") == "SIGabc=="
    assert enc.getAttribute("length") == "12345"
    os.unlink(p)

def test_idempotent_on_version():
    p = seed()
    add(p, "0.0.21", "2", "https://ex/a.zip", "SIG==", "1")
    add(p, "0.0.21", "2", "https://ex/a.zip", "SIG==", "1")
    assert len(minidom.parse(p).getElementsByTagName("item")) == 1  # not duplicated
    os.unlink(p)

if __name__ == "__main__":
    test_item_added_with_fields(); test_idempotent_on_version()
    print("OK")
```

- [ ] **Step 3: Run to verify it fails**

Run: `python3 Tests/scripts/test_appcast_add.py`
Expected: FAIL — `scripts/appcast_add.py` not found.

- [ ] **Step 4: Write the script**

Create `scripts/appcast_add.py`:

```python
#!/usr/bin/env python3
"""Prepend a signed Sparkle <item> to an appcast feed. Idempotent on shortVersion.
Usage: appcast_add.py <appcast.xml> <shortVersion> <build> <url> <edSignature> <length>"""
import sys, datetime
from xml.dom import minidom

def main(path, short, build, url, sig, length):
    doc = minidom.parse(path)
    channel = doc.getElementsByTagName("channel")[0]
    # Idempotent: skip if an item already advertises this shortVersionString.
    for enc in doc.getElementsByTagName("enclosure"):
        if enc.getAttribute("sparkle:shortVersionString") == short:
            return
    item = doc.createElement("item")
    title = doc.createElement("title")
    title.appendChild(doc.createTextNode(f"Ignition Browser {short}"))
    item.appendChild(title)
    pub = doc.createElement("pubDate")
    # RFC-822-ish; Sparkle is lenient. Use a fixed-format UTC stamp.
    pub.appendChild(doc.createTextNode(
        datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")))
    item.appendChild(pub)
    minver = doc.createElement("sparkle:minimumSystemVersion")
    minver.appendChild(doc.createTextNode("14.0"))
    item.appendChild(minver)
    enc = doc.createElement("enclosure")
    enc.setAttribute("url", url)
    enc.setAttribute("sparkle:version", build)
    enc.setAttribute("sparkle:shortVersionString", short)
    enc.setAttribute("sparkle:edSignature", sig)
    enc.setAttribute("length", length)
    enc.setAttribute("type", "application/octet-stream")
    item.appendChild(enc)
    # Newest first: insert before any existing item, else append to channel.
    existing = channel.getElementsByTagName("item")
    if existing:
        channel.insertBefore(item, existing[0])
    else:
        channel.appendChild(item)
    with open(path, "w", encoding="utf-8") as f:
        f.write(doc.toxml())

if __name__ == "__main__":
    main(*sys.argv[1:7])
```

- [ ] **Step 5: Run to verify it passes**

Run: `python3 Tests/scripts/test_appcast_add.py`
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add scripts/appcast_add.py Tests/scripts/test_appcast_add.py docs/appcast.xml
git commit -m "scripts: appcast_add.py (idempotent signed item) + initial appcast.xml"
```

---

### Task 3: Sparkle dependency + EdDSA keys + Info.plist

**Files:**
- Modify: `Package.swift`
- Modify: `Resources/Info.plist`

- [ ] **Step 1: Add Sparkle to Package.swift**

In `Package.swift`, remove the `TODO(M6)` Sparkle comment, and set `dependencies`/`targets`:

```swift
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "IgnitionBrowser",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/IgnitionBrowser"
        ),
        .testTarget(
            name: "IgnitionBrowserTests",
            dependencies: ["IgnitionBrowser"],
            path: "Tests/IgnitionBrowserTests"
        )
    ]
```

- [ ] **Step 2: Resolve + build to fetch Sparkle**

Run: `swift build`
Expected: Sparkle resolves and the build completes (`Build complete!`).

- [ ] **Step 3: Generate the EdDSA keypair (one-time, manual)**

Run (uses the resolved Sparkle tools):

```bash
BIN=$(find .build -path '*/Sparkle/bin/generate_keys' | head -1)
"$BIN"            # prints the PUBLIC key; stores PRIVATE key in the login keychain
"$BIN" -x /tmp/sparkle_priv.key   # export the private key for the CI secret
```

Record outputs:
- Add the printed **public** key to `Resources/Info.plist` as `SUPublicEDKey` (Step 4).
- Add the file `/tmp/sparkle_priv.key` contents as repo secret `SPARKLE_ED_PRIVATE_KEY`:
  `gh secret set SPARKLE_ED_PRIVATE_KEY < /tmp/sparkle_priv.key && rm /tmp/sparkle_priv.key`

- [ ] **Step 4: Add Sparkle keys to Info.plist**

In `Resources/Info.plist`, inside the top-level `<dict>` (e.g. after `LSUIElement`), add:

```xml
    <key>SUFeedURL</key>
    <string>https://vadika.github.io/ignition-browser/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>PASTE_THE_PUBLIC_KEY_FROM_STEP_3</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
```

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved Resources/Info.plist
git commit -m "sparkle: add dependency + Info.plist feed/key (silent auto-update)"
```

---

### Task 4: Updater controller + menu item

**Files:**
- Modify: `Sources/IgnitionBrowser/AppDelegate.swift`

- [ ] **Step 1: Import Sparkle and own the controller**

At the top of `AppDelegate.swift` add `import Sparkle` (after `import AppKit`). Add a stored property
alongside the others (e.g. after `private var hotKey: HotKey?`):

```swift
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
```

(Starting the updater here enables the scheduled background checks configured in Info.plist.)

- [ ] **Step 2: Add the "Check for Updates…" menu item**

In `installStatusItem()`, immediately before the version row (`let version = …`), insert:

```swift
        let upd = NSMenuItem(title: "Check for Updates…",
                             action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                             keyEquivalent: "")
        upd.target = updaterController
        menu.addItem(upd)
        menu.addItem(.separator())
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`.

- [ ] **Step 4: Run the test suite (nothing regressed)**

Run: `swift test`
Expected: existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/IgnitionBrowser/AppDelegate.swift
git commit -m "menu: Check for Updates… + start Sparkle updater"
```

---

### Task 5: Bundle + sign Sparkle in build-app.sh; appcast in release.yml

**Files:**
- Modify: `scripts/build-app.sh`
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Copy + deep-sign Sparkle.framework in build-app.sh**

In `scripts/build-app.sh`, after the release binary is built and the bundle dirs exist, before the
final app `codesign`, add (the `$DEV_ID` var is already defined later in the script — move the
`DEV_ID` empty-check above this block, or duplicate the guard here):

```bash
# Bundle Sparkle.framework (resolved by SwiftPM) and deep-sign inner-first: hardened
# runtime + timestamp on each nested executable, then the framework, then the app.
FRAMEWORKS="$CONTENTS/Frameworks"
mkdir -p "$FRAMEWORKS"
SPARKLE_SRC="$(find .build/release -maxdepth 1 -name Sparkle.framework | head -1)"
[ -n "$SPARKLE_SRC" ] || { echo "Sparkle.framework not found in .build/release" >&2; exit 1; }
cp -R "$SPARKLE_SRC" "$FRAMEWORKS/Sparkle.framework"
SPK="$FRAMEWORKS/Sparkle.framework/Versions/B"
for nested in \
  "$SPK/XPCServices/org.sparkle-project.Sparkle.Installer.xpc" \
  "$SPK/XPCServices/org.sparkle-project.Sparkle.Downloader.xpc" \
  "$SPK/Autoupdate" \
  "$SPK/Updater.app"; do
  [ -e "$nested" ] && codesign --force --options runtime --timestamp --sign "$DEV_ID" "$nested"
done
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$FRAMEWORKS/Sparkle.framework"
```

- [ ] **Step 2: Build the app locally to verify signing**

Run (needs your Developer ID): `DEV_ID="$DEV_ID" scripts/build-boot.sh >/dev/null 2>&1 || true; DEV_ID="$DEV_ID" scripts/build-app.sh`
Expected: `built: dist/IgnitionBrowser.app`. Then verify Sparkle is signed + valid:
`codesign --verify --deep --strict dist/IgnitionBrowser.app && echo OK`
Expected: `OK`.

- [ ] **Step 3: Add the appcast step to release.yml**

In `.github/workflows/release.yml`, after the "Notarize + staple" step and before/with the upload,
add a step:

```yaml
      - name: Sign update + update appcast
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: |
          set -euo pipefail
          ZIP=dist/IgnitionBrowser.app.zip
          SHORT="${GITHUB_REF_NAME#v}"                       # tag vX.Y.Z -> X.Y.Z
          BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
          URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${GITHUB_REF_NAME}/IgnitionBrowser.app.zip"
          LEN=$(stat -f%z "$ZIP")
          SIGN=$(find .build -path '*/Sparkle/bin/sign_update' | head -1)
          echo "$SPARKLE_ED_PRIVATE_KEY" > /tmp/ed_priv.key
          SIG=$("$SIGN" "$ZIP" -f /tmp/ed_priv.key | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
          rm -f /tmp/ed_priv.key
          python3 scripts/appcast_add.py docs/appcast.xml "$SHORT" "$BUILD" "$URL" "$SIG" "$LEN"
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git fetch origin main
          git checkout main
          git add docs/appcast.xml
          git commit -m "appcast: ${GITHUB_REF_NAME}" || echo "no appcast change"
          git push origin HEAD:main
```

> Note: `sign_update` is resolved by `swift build` earlier in the job; ensure a `swift build` step
> runs before this (the existing "Build .app" step does). `PlistBuddy` is available on the macOS runner.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-app.sh .github/workflows/release.yml
git commit -m "release: bundle+sign Sparkle, sign_update + appcast publish on tag"
```

> **Updater half is now complete and independently releasable.** Tagging a release produces a signed
> appcast item; an installed v(N-1) build will see + install v(N). Tasks 6–9 add the automation.

---

### Task 6: firefox-esr version tracker

**Files:**
- Create: `.firefox-esr-version`

- [ ] **Step 1: Seed the tracked version with the current Alpine value**

Run:

```bash
docker run --rm alpine:3.19 sh -c 'apk update -q && apk policy firefox-esr 2>/dev/null | sed -n "2p" | tr -d " " | cut -d: -f1' > .firefox-esr-version
cat .firefox-esr-version   # e.g. 115.18.0-r0
```

If Docker is unavailable locally, run the same on artemis2 and paste the value into the file.

- [ ] **Step 2: Commit**

```bash
git add .firefox-esr-version
git commit -m "watch: seed tracked Alpine firefox-esr version"
```

---

### Task 7: Self-hosted runner runbook (manual setup)

**Files:**
- Create: `docs/superpowers/runbooks/artemis2-self-hosted-runner.md`

- [ ] **Step 1: Write the runbook**

Create `docs/superpowers/runbooks/artemis2-self-hosted-runner.md`:

```markdown
# artemis2 self-hosted GitHub Actions runner

The firefox-watch rebuild job runs here (Docker + local registry live on artemis2).

## Register (one-time)
1. GitHub → repo Settings → Actions → Runners → New self-hosted runner (Linux x64).
2. On artemis2, follow the shown `./config.sh --url … --token …`. Add labels: `self-hosted,artemis2`.
3. Install as a service: `sudo ./svc.sh install && sudo ./svc.sh start`.

## Security (public repo)
- Settings → Actions → General → "Fork pull request workflows": require approval for all outside
  collaborators; do NOT allow forks to run workflows.
- The rebuild job is additionally guarded with `if: github.event_name != 'pull_request'`.
- Keep the runner in a dedicated runner group restricted to this repo.

## Prereqs on artemis2 (already present)
- Docker (arm64 emulation), `oras`, local registry at 127.0.0.1:5001, `~/firecracker-mac` checkout,
  `git` push creds for the repo, Python 3.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/runbooks/artemis2-self-hosted-runner.md
git commit -m "docs: artemis2 self-hosted runner runbook"
```

- [ ] **Step 3: Register the runner (perform the runbook)** — manual; confirm `gh api repos/:owner/:repo/actions/runners` lists an online `artemis2` runner before Task 9 can succeed.

---

### Task 8: firefox-watch — detect job

**Files:**
- Create: `.github/workflows/firefox-watch.yml`

- [ ] **Step 1: Write the detect job**

Create `.github/workflows/firefox-watch.yml`:

```yaml
name: firefox-watch

on:
  schedule:
    - cron: "17 6 * * *"      # daily 06:17 UTC
  workflow_dispatch:
    inputs:
      force_version:
        description: "Override detected firefox-esr version (testing)"
        required: false
        default: ""

permissions:
  contents: write

jobs:
  detect:
    runs-on: ubuntu-latest
    outputs:
      changed: ${{ steps.check.outputs.changed }}
      version: ${{ steps.check.outputs.version }}
    steps:
      - uses: actions/checkout@v4
      - id: check
        run: |
          set -euo pipefail
          if [ -n "${{ github.event.inputs.force_version }}" ]; then
            NEW="${{ github.event.inputs.force_version }}"
          else
            NEW=$(docker run --rm alpine:3.19 sh -c \
              'apk update -q && apk policy firefox-esr 2>/dev/null | sed -n "2p" | tr -d " " | cut -d: -f1')
          fi
          OLD=$(cat .firefox-esr-version 2>/dev/null || echo "")
          echo "detected=$NEW old=$OLD"
          if [ "$NEW" != "$OLD" ] && [ -n "$NEW" ]; then
            echo "changed=true" >> "$GITHUB_OUTPUT"
          else
            echo "changed=false" >> "$GITHUB_OUTPUT"
          fi
          echo "version=$NEW" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Validate the YAML + dispatch the detect path**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/firefox-watch.yml'))" && echo "yaml ok"`
Expected: `yaml ok`.
After committing/pushing, run: `gh workflow run firefox-watch.yml -f force_version=test-1.2.3` then
`gh run watch "$(gh run list --workflow=firefox-watch.yml -L1 --json databaseId -q '.[0].databaseId')"`.
Expected: the `detect` job logs `changed=true` (force value differs from the tracked one).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/firefox-watch.yml
git commit -m "watch: firefox-watch detect job (Alpine firefox-esr vs tracked)"
```

---

### Task 9: firefox-watch — rebuild + release job (artemis2)

**Files:**
- Modify: `.github/workflows/firefox-watch.yml`

- [ ] **Step 1: Append the rebuild job**

In `.github/workflows/firefox-watch.yml`, add a second job:

```yaml
  rebuild:
    needs: detect
    if: needs.detect.outputs.changed == 'true' && github.event_name != 'pull_request'
    runs-on: [self-hosted, artemis2]
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - name: Rebuild rootfs + publish assets
        run: |
          set -euo pipefail
          ( cd ~/firecracker-mac/kimage/build && bash ./build-rootfs-browser.sh )
          IGN_SHA=$(git -C vendor/ignition rev-parse --short=7 HEAD)
          scripts/publish-guest-assets.sh "$IGN_SHA"
          # also retag :latest so release.yml pulls the new rootfs
          ( cd ~/kbuild/out && oras push --plain-http 127.0.0.1:5001/ignition-browser/guest-assets:latest \
              Image:application/octet-stream rootfs-browser.ext4:application/octet-stream )
      - name: Bump version + tag (triggers release.yml)
        env:
          NEW_FF: ${{ needs.detect.outputs.version }}
        run: |
          set -euo pipefail
          printf '%s\n' "$NEW_FF" > .firefox-esr-version
          NEWVER=$(python3 scripts/bump_patch.py Resources/Info.plist)
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .firefox-esr-version Resources/Info.plist
          git commit -m "release: v${NEWVER} (firefox-esr ${NEW_FF})"
          git tag "v${NEWVER}"
          git push origin HEAD:main "v${NEWVER}"
```

- [ ] **Step 2: Validate YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/firefox-watch.yml'))" && echo "yaml ok"`
Expected: `yaml ok`.

- [ ] **Step 3: End-to-end dispatch (real)**

Pre-req: the artemis2 runner is online (Task 7). Run:
`gh workflow run firefox-watch.yml -f force_version=$(cat .firefox-esr-version)-test`
Watch both jobs. Expected: `detect` → `changed=true`; `rebuild` rebuilds the rootfs on artemis2,
publishes assets, bumps the patch, pushes a new `vX.Y.Z` tag; `release.yml` then runs and publishes
the release + appcast item.

> After a successful real run, reset the test artifacts if needed: revert the test version commit/tag
> (`git push origin :vX.Y.Z`) so a genuine Alpine bump drives the next real release.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/firefox-watch.yml
git commit -m "watch: rebuild+release job on artemis2 (rootfs -> publish -> patch bump -> tag)"
```

---

## Self-Review

**Spec coverage:**
- Sparkle dep + controller + menu + Info.plist keys → Tasks 3, 4. ✓
- build-app.sh Sparkle bundling/signing → Task 5 Step 1–2. ✓
- release.yml sign_update + appcast append + commit → Task 5 Step 3. ✓
- Appcast on Pages (`docs/appcast.xml`) → Task 2 Step 1. ✓
- Watcher (Alpine firefox-esr, daily cron, workflow_dispatch, `.firefox-esr-version`) → Tasks 6, 8. ✓
- Rebuild job on artemis2 self-hosted (build → publish → patch bump → tag), PR-guarded → Task 9 + runbook Task 7. ✓
- Single commit for version-file + bump (no race) → Task 9 Step 1 (one `git commit`). ✓
- Patch bump granularity → Task 1. ✓
- Error handling (build fail → no tag; idempotent watcher; idempotent appcast) → Task 2 (idempotent item), Task 8 (version gate), Task 9 (`if changed`). ✓
- Testing (Sparkle manual, watcher dispatch, rebuild dry-run via force) → Task 5 Step 2, Task 8 Step 2, Task 9 Step 3. ✓

**Placeholder scan:** `PASTE_THE_PUBLIC_KEY_FROM_STEP_3` / `force_version=test-…` are real runtime values
the engineer supplies, not unfinished plan text. No TBD/“add error handling”/uncoded steps.

**Type/name consistency:** `scripts/bump_patch.py` (prints new short version), `scripts/appcast_add.py`
(args: appcast, short, build, url, sig, length), `.firefox-esr-version`, `updaterController`,
`SUFeedURL`/`SUPublicEDKey`, job outputs `changed`/`version` — all used consistently across Tasks 1–9.
