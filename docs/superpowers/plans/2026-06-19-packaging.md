# ignition-browser packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a runnable, notarized `.app` that bundles all runtime assets (boot, gvproxy, kernel raw; rootfs gzip-compressed), builds the host-bound `browser-base` snapshot on first run with visible progress, then opens disposable Firefox microVMs.

**Architecture:** Bundle everything in `.app/Contents/Resources`. A Swift `FirstRun` module gunzips the rootfs to a temp file, spawns a build-time gvproxy + `boot --gui --control-sock`, waits for `BROWSER_READY` on boot's stdout, snapshots `browser-base` over the control socket, then deletes the temp rootfs. `build-app.sh` assembles + deep-signs; `release.yml` notarizes via the App Store Connect API key. Sparkle deferred.

**Tech Stack:** Swift 6 / AppKit, Foundation Process/FileManager, ignition `boot` (control-socket line-JSON), gvproxy, codesign/notarytool, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-06-19-packaging-design.md`

**Constraints:** plain commit messages (no co-author/Generated trailer); ponytail affected code before commit; this repo is `ignition-browser` (Swift package); `swift build` / `swift test` from repo root.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/IgnitionBrowser/Config.swift` (modify) | add `rootfsArchive: URL?` (bundled `.gz`) + `rootfsRaw: URL?` (dev raw ext4) |
| `Sources/IgnitionBrowser/FirstRun.swift` (create) | `isComplete` + `run` (preflight, gunzip, spawn gvproxy+boot, control-snapshot, cleanup); a line-JSON control client |
| `Sources/IgnitionBrowser/AppDelegate.swift` (modify) | gate startup on first-run; progress window; run on background thread |
| `Tests/IgnitionBrowserTests/FirstRunTests.swift` (create) | `isComplete` by snapshot presence; control-snapshot framing vs a fake server |
| `scripts/build-app.sh` (modify) | gzip rootfs + copy kernel/gvproxy + deep-sign nested + sign app |
| `scripts/notarize.sh` (modify) | App Store Connect API-key credential form for CI |
| `.github/workflows/release.yml` (modify) | import cert→keychain, set DEV_ID, notary API key, drop Sparkle |

---

## Task 1: Config — rootfs archive + raw paths

**Files:**
- Modify: `Sources/IgnitionBrowser/Config.swift`
- Test: `Tests/IgnitionBrowserTests/ConfigTests.swift` (create)

- [ ] **Step 1: Add the two fields + populate both branches**

In `Config.swift`, add to the struct (after `baseSnapshotName`):

```swift
    /// Bundled gzip-compressed rootfs (`Resources/rootfs-browser.ext4.gz`); nil in dev.
    let rootfsArchive: URL?
    /// Raw ext4 rootfs for dev (`vendor/ignition/kimage/out/rootfs-browser.ext4`); nil when bundled.
    let rootfsRaw: URL?
```

In the **bundled** `Config(...)` (the `if let resources` branch) add:
```swift
                rootfsArchive: resources.appendingPathComponent("rootfs-browser.ext4.gz"),
                rootfsRaw: nil,
```
In the **dev** `Config(...)` (the fallback `return`) add:
```swift
            rootfsArchive: nil,
            rootfsRaw: ignition.appendingPathComponent("kimage/out/rootfs-browser.ext4"),
```
(Insert both before the closing `)` of each `Config(...)`, keeping the existing fields.)

- [ ] **Step 2: Write the test**

Create `Tests/IgnitionBrowserTests/ConfigTests.swift`:
```swift
import XCTest
@testable import IgnitionBrowser

final class ConfigTests: XCTestCase {
    // In `swift test` there is no app bundle with a bundled `boot`, so resolve()
    // takes the dev branch: rootfsRaw set (vendor path), rootfsArchive nil.
    func testDevResolveUsesRawRootfs() {
        let c = Config.resolve()
        XCTAssertNil(c.rootfsArchive)
        XCTAssertNotNil(c.rootfsRaw)
        XCTAssertTrue(c.rootfsRaw!.path.hasSuffix("kimage/out/rootfs-browser.ext4"))
        XCTAssertEqual(c.baseSnapshotName, "browser-base")
    }
}
```

- [ ] **Step 3: Build + test**

Run: `swift test --filter ConfigTests`
Expected: PASS.

- [ ] **Step 4: Commit**
```bash
git add Sources/IgnitionBrowser/Config.swift Tests/IgnitionBrowserTests/ConfigTests.swift
git commit -m "config: rootfs archive (bundled .gz) + raw (dev) paths for first-run"
```

---

## Task 2: FirstRun module

**Files:**
- Create: `Sources/IgnitionBrowser/FirstRun.swift`
- Test: `Tests/IgnitionBrowserTests/FirstRunTests.swift`

- [ ] **Step 1: Write the module**

Create `Sources/IgnitionBrowser/FirstRun.swift`:
```swift
import Foundation
import Darwin

/// One-time setup: build the host-bound `browser-base` snapshot locally. The snapshot
/// cannot be shipped (it is bound to this host's CPU/kernel state), so we warm a guest
/// here and snapshot it. Idempotent: a no-op once the snapshot exists.
enum FirstRun {
    enum FirstRunError: Error, CustomStringConvertible {
        case lowDisk(freeGiB: Double)
        case missingRootfs
        case gunzipFailed(Int32)
        case bootSpawn(String)
        case browserReadyTimeout
        case snapshotTimeout
        case controlFailed(String)
        var description: String {
            switch self {
            case .lowDisk(let g): return "Not enough free disk space (\(String(format: "%.1f", g)) GiB; need ~4 GiB)."
            case .missingRootfs: return "No rootfs available to build the base from."
            case .gunzipFailed(let c): return "Decompressing the guest image failed (gunzip exit \(c))."
            case .bootSpawn(let m): return "Failed to start the VM: \(m)."
            case .browserReadyTimeout: return "The guest browser did not become ready in time."
            case .snapshotTimeout: return "The snapshot was not written in time."
            case .controlFailed(let m): return "Snapshot command failed: \(m)."
            }
        }
    }

    static func snapshotDir(_ config: Config) -> URL {
        config.store.appendingPathComponent("snapshots/\(config.baseSnapshotName)", isDirectory: true)
    }

    static func isComplete(_ config: Config) -> Bool {
        FileManager.default.fileExists(
            atPath: snapshotDir(config).appendingPathComponent("manifest.json").path)
    }

    /// Build `browser-base`. `progress` is called with human-readable status lines (main-thread
    /// dispatch is the caller's responsibility). Throws FirstRunError on failure; cleans up.
    static func run(_ config: Config, progress: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: config.store, withIntermediateDirectories: true)

        // 1. disk-space preflight (need ~4 GiB for the snapshot: memory.bin ~2G + disk ~1.5G).
        if let attrs = try? fm.attributesOfFileSystem(forPath: config.store.path),
           let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value {
            let freeGiB = Double(free) / 1_073_741_824.0
            if freeGiB < 4.0 { throw FirstRunError.lowDisk(freeGiB: freeGiB) }
        }

        // 2. obtain the rootfs (gunzip the bundled archive to a temp file, or use the dev raw image).
        let work = fm.temporaryDirectory.appendingPathComponent("ignbrowser-firstrun-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let rootfs: URL
        if let archive = config.rootfsArchive, fm.fileExists(atPath: archive.path) {
            progress("Decompressing guest image…")
            rootfs = work.appendingPathComponent("rootfs-browser.ext4")
            try gunzip(archive, to: rootfs)
        } else if let raw = config.rootfsRaw, fm.fileExists(atPath: raw.path) {
            rootfs = raw
        } else {
            throw FirstRunError.missingRootfs
        }

        // 3. sockets for this one-shot build.
        let gvSock = work.appendingPathComponent("gv.sock")
        let gvCtl = work.appendingPathComponent("gvctl.sock")
        let vsock = work.appendingPathComponent("vsock.sock")
        let ctl = work.appendingPathComponent("control.sock")

        progress("Starting network…")
        let gvproxy = try spawnGvproxy(config: config, qemuSock: gvSock, ctlSock: gvCtl)
        defer { gvproxy.terminate() }
        _ = waitForSocket(gvSock, timeout: 5)

        // 4. warm the guest under --gui; snapshot once BROWSER_READY appears on stdout.
        progress("Warming the browser (one-time, ~30–60s)…")
        let boot = Process()
        boot.executableURL = config.bootBinary
        boot.arguments = [
            "--gui", "--net", "--net-socket", gvSock.path,
            "--vsock-uds", vsock.path, "--control-sock", ctl.path,
            "--store", config.store.path, "--name", config.baseSnapshotName,
            "--append", "ro init=/sbin/overlay-init",
            config.kernelImage.path, rootfs.path,
        ]
        let outPipe = Pipe()
        boot.standardOutput = outPipe
        boot.standardError = outPipe
        do { try boot.run() } catch { throw FirstRunError.bootSpawn(error.localizedDescription) }
        defer { if boot.isRunning { boot.terminate() } }

        guard waitForLine(outPipe, marker: "BROWSER_READY", timeout: 120) else {
            throw FirstRunError.browserReadyTimeout
        }

        // 5. snapshot via the control socket (line-JSON), then wait for the manifest.
        progress("Saving the warm snapshot…")
        if let err = sendControl(ctl, json: "{\"action\":\"snapshot\",\"name\":\"\(config.baseSnapshotName)\"}", deadline: 10) {
            throw FirstRunError.controlFailed(err)
        }
        let manifest = snapshotDir(config).appendingPathComponent("manifest.json")
        let deadline = Date().addingTimeInterval(30)
        while !fm.fileExists(atPath: manifest.path) {
            if Date() >= deadline { throw FirstRunError.snapshotTimeout }
            Thread.sleep(forTimeInterval: 0.2)
        }
        progress("Ready.")
        // boot + gvproxy terminated by defers; temp work dir (incl. the decompressed rootfs) removed.
    }

    // MARK: - helpers

    private static func gunzip(_ src: URL, to dst: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", src.path]
        let out = FileManager.default.createFile(atPath: dst.path, contents: nil)
        guard out, let fh = FileHandle(forWritingAtPath: dst.path) else { throw FirstRunError.gunzipFailed(-1) }
        p.standardOutput = fh
        try p.run(); p.waitUntilExit(); try? fh.close()
        if p.terminationStatus != 0 { throw FirstRunError.gunzipFailed(p.terminationStatus) }
    }

    // ponytail: ~6-line dup of SessionManager.spawnGvproxy; extract Gvproxy.spawn if a 3rd caller appears.
    private static func spawnGvproxy(config: Config, qemuSock: URL, ctlSock: URL) throws -> Process {
        let p = Process()
        p.executableURL = config.gvproxyBinary
        p.arguments = ["-listen", "unix://\(ctlSock.path)", "-listen-qemu", "unix://\(qemuSock.path)"]
        do { try p.run() } catch { throw FirstRunError.bootSpawn("gvproxy: \(error.localizedDescription)") }
        return p
    }

    private static func waitForSocket(_ url: URL, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Read `pipe` until a line containing `marker` appears or `timeout` elapses.
    private static func waitForLine(_ pipe: Pipe, marker: String, timeout: TimeInterval) -> Bool {
        let fh = pipe.fileHandleForReading
        let end = Date().addingTimeInterval(timeout)
        var buf = Data()
        while Date() < end {
            let chunk = fh.availableData          // blocks until data or EOF
            if chunk.isEmpty { return false }     // EOF (boot exited)
            buf.append(chunk)
            if let s = String(data: buf, encoding: .utf8), s.contains(marker) { return true }
            if buf.count > 1_048_576 { buf.removeFirst(buf.count - 65_536) } // cap memory
        }
        return false
    }

    /// Connect boot's --control-sock, write one JSON line, read the reply; nil on success,
    /// else an error string. (Direct line-JSON; not the vsock CONNECT protocol.)
    private static func sendControl(_ sock: URL, json: String, deadline: TimeInterval) -> String? {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 { Thread.sleep(forTimeInterval: 0.1); continue }
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(sock.path.utf8)
            let cap = MemoryLayout.size(ofValue: addr.sun_path)
            if bytes.count >= cap { close(fd); return "control path too long" }
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                    for (i, b) in bytes.enumerated() { dst[i] = b }; dst[bytes.count] = 0
                }
            }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            if !ok { close(fd); Thread.sleep(forTimeInterval: 0.1); continue }
            let line = json + "\n"
            _ = line.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, strlen($0.baseAddress!)) }
            var reply = [UInt8](); var byte: UInt8 = 0
            while reply.last != UInt8(ascii: "\n") {
                if read(fd, &byte, 1) <= 0 { break }
                reply.append(byte); if reply.count > 256 { break }
            }
            close(fd)
            let r = String(decoding: reply, as: UTF8.self)
            return r.contains("\"ok\":true") ? nil : "control reply: \(r.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return "control socket never answered"
    }
}
```

- [ ] **Step 2: Write the tests**

Create `Tests/IgnitionBrowserTests/FirstRunTests.swift`:
```swift
import XCTest
@testable import IgnitionBrowser

final class FirstRunTests: XCTestCase {
    private func tmpConfig() -> (Config, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cfg = Config(bootBinary: URL(fileURLWithPath: "/bin/true"),
                         kernelImage: URL(fileURLWithPath: "/k"),
                         gvproxyBinary: URL(fileURLWithPath: "/g"),
                         store: dir,
                         baseSnapshotName: "browser-base",
                         rootfsArchive: nil, rootfsRaw: URL(fileURLWithPath: "/r.ext4"))
        return (cfg, dir)
    }

    func testIsCompleteFalseThenTrue() throws {
        let (cfg, dir) = tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FirstRun.isComplete(cfg))
        let snap = FirstRun.snapshotDir(cfg)
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snap.appendingPathComponent("manifest.json"))
        XCTAssertTrue(FirstRun.isComplete(cfg))
    }
}
```
(`Config`'s memberwise init is internal to the module — `@testable import` gives access. If the compiler reports the init is private, add an explicit `init` to `Config` matching its stored properties.)

- [ ] **Step 3: Build + test**

Run: `swift test --filter FirstRunTests`
Expected: PASS (`testIsCompleteFalseThenTrue`).
Run: `swift build`
Expected: compiles (FirstRun.swift included).

- [ ] **Step 4: Commit**
```bash
git add Sources/IgnitionBrowser/FirstRun.swift Tests/IgnitionBrowserTests/FirstRunTests.swift
git commit -m "first-run: build browser-base locally (gunzip rootfs, warm guest, control-socket snapshot)"
```

---

## Task 3: AppDelegate — gate startup on first-run with progress

**Files:**
- Modify: `Sources/IgnitionBrowser/AppDelegate.swift`

- [ ] **Step 1: Replace the TODO with the first-run gate**

In `applicationDidFinishLaunching`, replace the line
`// TODO(M5): first-run setup (download rootfs, build+warm browser-base snapshot with progress).`
with:
```swift
        installStatusItem()
        registerServices()

        let config = Config.resolve()
        if !FirstRun.isComplete(config) {
            runFirstRun(config)
        }
```
Remove the duplicate `installStatusItem()` / `registerServices()` that were below the TODO (they now run before the gate so the menu bar is present during setup). The method becomes:
```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        sessions.sweepOrphans()
        installStatusItem()
        registerServices()
        let config = Config.resolve()
        if !FirstRun.isComplete(config) {
            runFirstRun(config)
        }
    }
```

- [ ] **Step 2: Add the progress window + background run**

Add to `AppDelegate`:
```swift
    private var firstRunWindow: NSWindow?

    private func runFirstRun(_ config: Config) {
        let label = NSTextField(labelWithString: "Preparing Ignition Browser…")
        label.frame = NSRect(x: 20, y: 24, width: 360, height: 24)
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 56, width: 360, height: 20))
        spinner.style = .bar; spinner.isIndeterminate = true; spinner.startAnimation(nil)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Ignition Browser"
        win.contentView?.addSubview(label); win.contentView?.addSubview(spinner)
        win.center(); win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        firstRunWindow = win

        DispatchQueue.global().async {
            do {
                try FirstRun.run(config) { msg in
                    DispatchQueue.main.async { label.stringValue = msg }
                }
                DispatchQueue.main.async { self.firstRunWindow?.close(); self.firstRunWindow = nil }
            } catch {
                DispatchQueue.main.async {
                    self.firstRunWindow?.close(); self.firstRunWindow = nil
                    let a = NSAlert()
                    a.messageText = "Setup failed"
                    a.informativeText = "\(error)"
                    a.runModal()
                    NSApp.terminate(nil)
                }
            }
        }
    }
```
(`@MainActor` AppDelegate: the `DispatchQueue.main.async` closures touching `self`/UI are correct; `FirstRun.run` is on a background queue. If Swift 6 strict-concurrency flags capture of `config` (a value type) or `label` (AppKit, main-actor), mark the global-async closure `@Sendable` and hop `label` updates through `DispatchQueue.main.async` only — as written.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: compiles, no warnings. (If strict-concurrency errors appear on the AppKit captures, resolve by confining all `label`/`win` access to the main queue — the structure above already does.)

- [ ] **Step 4: Commit**
```bash
git add Sources/IgnitionBrowser/AppDelegate.swift
git commit -m "app: gate launch on first-run with a progress window"
```

---

## Task 4: build-app.sh — gzip rootfs, bundle kernel/gvproxy, deep-sign

**Files:**
- Modify: `scripts/build-app.sh`

- [ ] **Step 1: Replace the asset-copy TODO block + add gvproxy signing**

In `scripts/build-app.sh`, replace the block from `cp "vendor/ignition/target/release/boot" "$RES/boot"` through the `# TODO(M5): rootfs ...` comment with:
```bash
cp "vendor/ignition/target/release/boot" "$RES/boot"
cp "$REPO_ROOT/dist/gvproxy" "$RES/gvproxy"
cp "vendor/ignition/kimage/out/Image" "$RES/Image"
# Rootfs is large but mostly sparse: gzip it; FirstRun gunzips on first launch.
gzip -c "vendor/ignition/kimage/out/rootfs-browser.ext4" > "$RES/rootfs-browser.ext4.gz"
```
And replace the `# TODO(M3): sign "$RES/gvproxy" ...` line with an actual sign before the app sign:
```bash
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$RES/boot"
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$RES/gvproxy"
```
(Leave the final app `codesign … --entitlements … "$APP"` as-is. Prereqs, stated in the header comment: `scripts/build-boot.sh` produced `vendor/ignition/target/release/boot`, `scripts/build-gvproxy.sh` produced `dist/gvproxy`, and `vendor/ignition/kimage/out/{Image,rootfs-browser.ext4}` exist.)

- [ ] **Step 2: Update the header comment**

Change the top comment to note all bundled assets + the two build prereqs (build-boot.sh, build-gvproxy.sh) and that the kernel/rootfs come from `vendor/ignition/kimage/out/`.

- [ ] **Step 3: Syntax check**

Run: `bash -n scripts/build-app.sh`
Expected: no output (valid).

- [ ] **Step 4: Commit**
```bash
git add scripts/build-app.sh
git commit -m "build-app: bundle gvproxy+kernel, gzip rootfs, deep-sign nested binaries"
```

---

## Task 5: notarize.sh — App Store Connect API-key credential

**Files:**
- Modify: `scripts/notarize.sh`

- [ ] **Step 1: Support API-key creds (CI) with keychain-profile fallback (local)**

Replace the `NOTARY_PROFILE` guard + the `notarytool submit` line with:
```bash
ZIP="dist/IgnitionBrowser.app.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# CI: App Store Connect API key. Local: a stored keychain profile.
if [[ -n "${NOTARY_KEY:-}" ]]; then
    xcrun notarytool submit "$ZIP" \
        --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
else
    echo "error: set NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER (CI) or NOTARY_PROFILE (local)." >&2
    exit 1
fi

xcrun stapler staple "$APP"
echo "notarized + stapled: $APP"
```
(Remove the old `NOTARY_PROFILE`-only guard and the now-duplicated `ditto`/`submit`/`staple`/`echo` lines; `$NOTARY_KEY` is a path to the `.p8` file.)

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/notarize.sh`
Expected: no output.

- [ ] **Step 3: Commit**
```bash
git add scripts/notarize.sh
git commit -m "notarize: App Store Connect API-key creds for CI (keychain-profile fallback)"
```

---

## Task 6: release.yml — secret wiring, drop Sparkle

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Add cert→keychain import + gvproxy build + API-key notarize; drop Sparkle**

Replace the `steps:` list with:
```yaml
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable

      - name: Install Go (for gvproxy)
        uses: actions/setup-go@v5
        with:
          go-version: stable

      - name: Import Developer ID cert
        env:
          CERT_P12: ${{ secrets.DEVELOPER_ID_CERT_P12 }}
          CERT_PW: ${{ secrets.DEVELOPER_ID_CERT_PASSWORD }}
        run: |
          KEYCHAIN="$RUNNER_TEMP/build.keychain"
          KPW=$(uuidgen)
          security create-keychain -p "$KPW" "$KEYCHAIN"
          security set-keychain-settings -lut 21600 "$KEYCHAIN"
          security unlock-keychain -p "$KPW" "$KEYCHAIN"
          echo "$CERT_P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"
          security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" -P "$CERT_PW" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: -s -k "$KPW" "$KEYCHAIN"
          security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
          echo "DEV_ID=$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'\"' 'NR==1{print $2}')" >> "$GITHUB_ENV"

      - name: Build + sign boot
        run: scripts/build-boot.sh

      - name: Build filtered gvproxy
        run: scripts/build-gvproxy.sh

      - name: Build .app
        run: scripts/build-app.sh

      - name: Notarize + staple
        env:
          NOTARY_KEY: ${{ runner.temp }}/notary.p8
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER: ${{ secrets.NOTARY_ISSUER }}
          NOTARY_API_KEY_B64: ${{ secrets.NOTARY_API_KEY }}
        run: |
          echo "$NOTARY_API_KEY_B64" | base64 --decode > "$RUNNER_TEMP/notary.p8"
          scripts/notarize.sh

      - name: Upload to GitHub release
        uses: softprops/action-gh-release@v2
        with:
          files: dist/IgnitionBrowser.app.zip
```
Update the `# Required repository secrets:` comment block at the top to list: `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `NOTARY_API_KEY` (base64 `.p8`), `NOTARY_KEY_ID`, `NOTARY_ISSUER`. Remove `SPARKLE_ED_PRIVATE_KEY` and `DEVELOPER_ID_NAME`/`NOTARY_PROFILE` references.

- [ ] **Step 2: Lint the YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**
```bash
git add .github/workflows/release.yml
git commit -m "ci: import Developer ID cert, build gvproxy, API-key notarize; drop Sparkle"
```

---

## Final verification (after all tasks)

- [ ] `swift build` clean; `swift test` all pass (Config + FirstRun + existing URLValidator/VsockClient).
- [ ] `bash -n scripts/build-app.sh scripts/notarize.sh` clean; release.yml YAML loads.
- [ ] **Live (M-series HVF, by hand):** build boot + gvproxy + kernel/rootfs in `vendor/ignition`; `DEV_ID=- scripts/build-app.sh` (adhoc) → `codesign --verify --deep --strict dist/IgnitionBrowser.app` passes; launch the `.app`, confirm first-run builds `browser-base` with progress, then "New Ignition Browser" opens Firefox.
- [ ] **Acceptance (clean second Mac):** a CI-notarized, stapled `.app` runs first-run and opens a disposable browser that loads a page and cannot reach the host LAN — no Terminal/sudo/Homebrew.

---

## Self-Review

**Spec coverage:** bundle-all + gzip rootfs → Task 4; Config archive/raw → Task 1; FirstRun (preflight, gunzip-to-temp, gvproxy+boot --control-sock, BROWSER_READY, control snapshot, cleanup) → Task 2; AppDelegate progress gate → Task 3; notarize API-key → Task 5; release.yml secret wiring + drop Sparkle → Task 6. Disk-space preflight, idempotent first-run, BROWSER_READY/snapshot timeouts → Task 2. Non-goals (Sparkle/download/DMG) not built.

**Placeholders:** none — every code step is complete. The only `// ponytail:` note (gvproxy spawn dup) is a deliberate, labeled simplification, not a gap.

**Type consistency:** `Config` gains `rootfsArchive: URL?` + `rootfsRaw: URL?`, used identically in Tasks 1/2/4. `FirstRun.isComplete`/`run`/`snapshotDir` signatures match between module (Task 2) and AppDelegate (Task 3) and tests. `browser-base` name + `manifest.json` sentinel consistent. Script env vars (`DEV_ID`, `NOTARY_KEY`/`KEY_ID`/`ISSUER`) match between notarize.sh (Task 5) and release.yml (Task 6).

**Open risk flagged for the implementer:** Swift 6 strict-concurrency around the AppKit captures in Task 3 and the `Config` memberwise-init visibility in the Task 2 test — both noted inline with the resolution.
