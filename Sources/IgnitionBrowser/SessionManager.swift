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

    /// Root holding all per-session socket dirs; sweepOrphans globs this. Kept SHORT:
    /// macOS unix-socket paths cap at 104 bytes (sockaddr_un.sun_path), and
    /// $TMPDIR + a full UUID + "gvproxy-ctl.sock" overflows it, so gvproxy/boot fail
    /// to bind ("bind: invalid argument") and a session silently never starts.
    private var sessionsRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ib", isDirectory: true)
    }

    /// Discoverable per-session serial logs (boot stdout/stderr = the guest serial
    /// console: kiosk-loop lines + kernel dmesg). For diagnosing restored-session
    /// issues — the "Reveal Logs" menu item opens this dir.
    static let logsDir: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/IgnitionBrowser", isDirectory: true)

    // MARK: - Open

    func openSession(url: URL?) {
        let id = UUID().uuidString
        // Short dir name (8 hex, not the full UUID) so socket paths stay under 104 bytes.
        let dir = sessionsRoot.appendingPathComponent(String(id.prefix(8)), isDirectory: true)
        let gvproxySock = dir.appendingPathComponent("gvproxy.sock")
        let gvproxyCtl = dir.appendingPathComponent("gvproxy-ctl.sock")
        let vsockUds = dir.appendingPathComponent("vsock.sock")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("IgnitionBrowser: failed to create session dir: \(error)")
            return
        }

        let session = Session(id: id, dir: dir, gvproxySock: gvproxySock,
                              gvproxyCtl: gvproxyCtl, vsockUds: vsockUds)
        lock.lock()
        sessions[id] = session
        lock.unlock()

        guard launchVM(id) else {
            destroySession(id: id)
            return
        }

        if let url {
            injectURL(url, session: id)
        }
    }

    /// boot's exit code requesting a cold-reset relaunch (Ctrl+Alt+R under --gui).
    /// Must match `RESET_RELAUNCH_EXIT` in ignition's display_sink.rs.
    private static let resetRelaunchExit: Int32 = 42

    /// Spawn gvproxy + boot for an already-registered session and wire the termination
    /// handler. Reused for the initial open AND for the Ctrl+Alt+R cold reset: boot
    /// exits with `resetRelaunchExit`, and rather than tear the session down we
    /// re-restore the clone from the snapshot (a fresh disposable session). Returns
    /// false if the VM could not be started.
    private func launchVM(_ id: String) -> Bool {
        lock.lock()
        guard let session = sessions[id] else { lock.unlock(); return false }
        lock.unlock()

        // A reset relaunch reuses the session dir. The prior gvproxy is single-client
        // and exits when boot disconnects, but terminate it defensively and clear its
        // sockets so the fresh gvproxy can bind.
        if let old = session.gvproxy, old.isRunning { old.terminate() }
        try? FileManager.default.removeItem(at: session.gvproxySock)
        try? FileManager.default.removeItem(at: session.gvproxyCtl)

        // One filtered gvproxy per session child; it must be up (qemu socket bound)
        // before boot, which connects to --net-socket on startup.
        guard let gvproxy = spawnGvproxy(qemuSock: session.gvproxySock, ctlSock: session.gvproxyCtl) else {
            return false
        }
        if !waitForSocket(session.gvproxySock, timeout: 5) {
            NSLog("IgnitionBrowser: gvproxy qemu socket never came up")
            gvproxy.terminate()
            return false
        }

        // Spawn the boot child. argv array — NEVER a shell string. rootfs comes from
        // the snapshot, so no positional rootfs disk is passed.
        let boot = Process()
        boot.executableURL = config.bootBinary
        boot.arguments = [
            "--gui",
            "--restore", config.baseSnapshotName,
            "--store", config.store.path,
            "--net", "--net-socket", session.gvproxySock.path,
            "--vsock-uds", session.vsockUds.path,
            config.kernelImage.path,
        ]
        boot.terminationHandler = { [weak self] proc in
            guard let self else { return }
            if proc.terminationStatus == Self.resetRelaunchExit {
                if !self.launchVM(id) { self.destroySession(id: id) }
            } else {
                self.destroySession(id: id)
            }
        }

        // Capture boot's serial console (kiosk-loop + guest dmesg) to a per-session log
        // for diagnostics. Append so Ctrl+Alt+R relaunches accumulate in one file. The
        // FileHandle is owned by `boot` and its fd is closed when boot is released.
        try? FileManager.default.createDirectory(at: Self.logsDir, withIntermediateDirectories: true)
        let logURL = Self.logsDir.appendingPathComponent("session-\(String(id.prefix(8))).log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let logFH = try? FileHandle(forWritingTo: logURL) {
            logFH.seekToEndOfFile()
            boot.standardOutput = logFH
            boot.standardError = logFH
        }

        do {
            try boot.run()
        } catch {
            NSLog("IgnitionBrowser: failed to spawn boot: \(error)")
            gvproxy.terminate()
            return false
        }

        lock.lock()
        if var s = sessions[id] {
            s.boot = boot
            s.gvproxy = gvproxy
            sessions[id] = s
        }
        lock.unlock()
        return true
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
            // Disable gvproxy's default 127.0.0.1:2222 SSH forward. We never SSH into the
            // guest (URLs go over vsock), and the fixed port means a second gvproxy —
            // another session, or a leftover — fails with "address already in use" and the
            // session never gets net. -1 = no forwards.
            "-ssh-port", "-1",
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
