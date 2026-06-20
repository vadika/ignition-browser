import AppKit

/// The spawn-subprocess core. One `boot --gui` child per disposable session;
/// the child owns its own winit NSWindow (v1 window model). Close window ->
/// boot exits -> terminationHandler -> destroySession.
///
/// @unchecked Sendable: mutable state (`sessions`) is guarded by `lock`, and the
/// terminationHandler runs off the main actor.
final class SessionManager: @unchecked Sendable {
    static let shared = SessionManager()

    private let config = Config.resolve()

    private struct Session {
        let id: String
        let dir: URL          // per-session temp dir (control sock, gvproxy sock)
        let gvproxySock: URL  // gvproxy qemu stream socket (boot --net-socket peer)
        let gvproxyCtl: URL   // gvproxy control endpoint (-listen)
        let vsockUds: URL     // boot --vsock-uds: host UDS bridging to guest vsock ports
        var boot: Process?
        var gvproxy: Process?
    }

    private var sessions: [String: Session] = [:]
    private let lock = NSLock()

    /// Root holding all per-session temp dirs; sweepOrphans globs this.
    private var sessionsRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IgnitionBrowser/sessions", isDirectory: true)
    }

    // MARK: - Open

    func openSession(url: URL?) {
        let id = UUID().uuidString
        let dir = sessionsRoot.appendingPathComponent(id, isDirectory: true)
        let gvproxySock = dir.appendingPathComponent("gvproxy.sock")
        let gvproxyCtl = dir.appendingPathComponent("gvproxy-ctl.sock")
        let vsockUds = dir.appendingPathComponent("vsock.sock")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("IgnitionBrowser: failed to create session dir: \(error)")
            return
        }

        var session = Session(id: id, dir: dir, gvproxySock: gvproxySock,
                              gvproxyCtl: gvproxyCtl, vsockUds: vsockUds)

        // One filtered gvproxy per session child (gvproxy is single-client: it exits
        // when its qemu peer disconnects). It must be up — its qemu socket bound —
        // before boot, which connects to --net-socket on startup.
        guard let gvproxy = spawnGvproxy(qemuSock: gvproxySock, ctlSock: gvproxyCtl) else {
            cleanupFiles(dir: dir)
            return
        }
        session.gvproxy = gvproxy
        if !waitForSocket(gvproxySock, timeout: 5) {
            NSLog("IgnitionBrowser: gvproxy qemu socket never came up")
            gvproxy.terminate()
            cleanupFiles(dir: dir)
            return
        }

        // Spawn the boot child. argv array — NEVER a shell string.
        // rootfs comes from the snapshot, so no positional rootfs disk is passed.
        // TODO(M2): warm-parent management + re-warm after each claim. For the skeleton
        // each session restores from browser-base directly (still fast via MAP_PRIVATE);
        // the parent-rewarm optimization is deferred.
        let boot = Process()
        boot.executableURL = config.bootBinary
        boot.arguments = [
            "--gui",
            "--restore", config.baseSnapshotName,
            "--store", config.store.path,
            "--net", "--net-socket", gvproxySock.path,
            "--vsock-uds", vsockUds.path,
            config.kernelImage.path,
        ]
        boot.terminationHandler = { [weak self] _ in
            self?.destroySession(id: id)
        }

        do {
            try boot.run()
        } catch {
            NSLog("IgnitionBrowser: failed to spawn boot: \(error)")
            gvproxy.terminate()
            cleanupFiles(dir: dir)
            return
        }
        session.boot = boot

        lock.lock()
        sessions[id] = session
        lock.unlock()

        if let url {
            injectURL(url, session: id)
        }
    }

    /// Spawn one filtered gvproxy for this session: user-mode NAT/DNS over a qemu
    /// stream socket that `boot --net-socket` connects to. The binary is the
    /// egress-filtered build (`scripts/build-gvproxy.sh` -> dist/gvproxy): it refuses
    /// to dial the host / host LAN / private ranges, so the guest gets public NAT only.
    private func spawnGvproxy(qemuSock: URL, ctlSock: URL) -> Process? {
        let p = Process()
        p.executableURL = config.gvproxyBinary
        p.arguments = [
            "-listen", "unix://\(ctlSock.path)",
            "-listen-qemu", "unix://\(qemuSock.path)",
        ]
        do {
            try p.run()
        } catch {
            NSLog("IgnitionBrowser: failed to spawn gvproxy at \(config.gvproxyBinary.path): \(error)")
            return nil
        }
        return p
    }

    /// Poll until a unix socket path exists (gvproxy binds asynchronously after spawn).
    private func waitForSocket(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Send the validated URL to the guest's port-7777 URL listener (open-url),
    /// which navigates the running kiosk Firefox. Runs off-main; best-effort.
    private func injectURL(_ url: URL, session id: String) {
        lock.lock(); let uds = sessions[id]?.vsockUds.path; lock.unlock()
        guard let uds else { return }
        let urlString = url.absoluteString
        Thread.detachNewThread {
            let ok = VsockClient.sendLine(udsPath: uds, port: 7777, line: urlString, deadline: 30)
            if !ok { NSLog("IgnitionBrowser: URL injection failed for session \(id)") }
        }
    }

    // MARK: - Destroy

    func destroySession(id: String) {
        lock.lock()
        let session = sessions.removeValue(forKey: id)
        lock.unlock()
        guard let session else { return }

        if let boot = session.boot, boot.isRunning {
            boot.terminate()
        }
        if let gvproxy = session.gvproxy, gvproxy.isRunning {
            gvproxy.terminate()
        }
        cleanupFiles(dir: session.dir)
    }

    private func cleanupFiles(dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Orphan sweep

    /// On launch, delete any leftover session temp dirs/clones from a prior crash.
    func sweepOrphans() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }
}
