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

    /// vCPUs baked into browser-base. The guest renders Firefox with llvmpipe (software
    /// GL, multithreaded), so a 1-vCPU base repaints painfully slowly — keystrokes and
    /// clicks land but their on-screen effect lags. 4 gives llvmpipe room without
    /// pinning the host. (boot's default is 1, and we used to pass no --smp at all.)
    static let baseVcpus = 4

    /// Bump when a base-build parameter that is NOT captured by file sizes or baseVcpus
    /// changes — notably the boot binary's guest resolution (GUI_W/GUI_H). r2 = the
    /// 1400x880 integer-scaled window (ignition 0cf9d1c).
    static let baseRecipeVersion = 2

    /// Fingerprint of the bundled guest assets + the base-build recipe. Changes whenever
    /// the shipped guest OR a build parameter (vCPU count, recipe version) changes, so an
    /// upgraded app rebuilds browser-base instead of silently restoring a stale snapshot.
    static func guestStamp(_ config: Config) -> String {
        let fm = FileManager.default
        func size(_ url: URL?) -> Int64 {
            guard let url, let a = try? fm.attributesOfItem(atPath: url.path) else { return 0 }
            return (a[.size] as? NSNumber)?.int64Value ?? 0
        }
        return "\(size(config.rootfsArchive ?? config.rootfsRaw))-\(size(config.kernelImage))-smp\(baseVcpus)-r\(baseRecipeVersion)"
    }

    private static func stampFile(_ config: Config) -> URL {
        snapshotDir(config).appendingPathComponent(".guest-stamp")
    }

    static func isComplete(_ config: Config) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshotDir(config).appendingPathComponent("manifest.json").path)
        else { return false }
        let stamp = (try? String(contentsOf: stampFile(config), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stamp == guestStamp(config)
    }

    /// Build `browser-base`. `progress` is called with human-readable status lines (main-thread
    /// dispatch is the caller's responsibility). Throws FirstRunError on failure; cleans up.
    static func run(_ config: Config, progress: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: config.store, withIntermediateDirectories: true)
        // Drop any stale base (e.g. one left by a previous app version) so we rebuild clean.
        try? fm.removeItem(at: snapshotDir(config))

        // 1. disk-space preflight (need ~4 GiB for the snapshot: memory.bin ~2G + disk ~1.5G).
        if let attrs = try? fm.attributesOfFileSystem(forPath: config.store.path),
           let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value {
            let freeGiB = Double(free) / 1_073_741_824.0
            if freeGiB < 4.0 { throw FirstRunError.lowDisk(freeGiB: freeGiB) }
        }

        // 2. obtain the rootfs (gunzip the bundled archive to a temp file, or use the dev raw image).
        // Short dir name: macOS unix-socket paths cap at 104 bytes, and FirstRun's
        // gvproxy/boot sockets live under here — a full UUID overflows the limit.
        let work = fm.temporaryDirectory.appendingPathComponent("ib-fr-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
            "--smp", "\(Self.baseVcpus)",
            // --gui-hidden: the guest renders + snapshots normally but the host window
            // stays hidden, so the warming browser never flashes a clickable window.
            "--gui-hidden", "--net", "--net-socket", gvSock.path,
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
        // Stamp the store with the guest fingerprint so isComplete() can detect a future
        // asset change and rebuild. Written last: only a fully-built base counts as complete.
        try? guestStamp(config).write(to: stampFile(config), atomically: true, encoding: .utf8)
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
            // `timeout` is enforced only between reads: availableData blocks, so the deadline is checked after each read returns (relies on boot emitting serial output steadily, which it does).
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
