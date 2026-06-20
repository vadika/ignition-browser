import Foundation
import Darwin

/// Minimal AF_UNIX client for ignition's boot `--vsock-uds` host→guest bridge.
///
/// Protocol (host side): connect the UDS, send `CONNECT <port>\n`, then read an
/// ack line. `OK <n>\n` means the guest port is listening and the socket is now
/// a raw bidirectional stream to that guest listener. If the guest port is not
/// yet listening, boot closes the connection without an OK — so the full
/// connect+handshake is retried until a deadline (the guest listener comes up a
/// few hundred ms to seconds after boot, via openrc).
enum VsockClient {
    /// Connect to boot's vsock UDS, CONNECT to `port`, await "OK", send `line`
    /// (a single newline-terminated message), then close. Retries the full
    /// connect+handshake until `deadline` seconds elapse (the guest listener
    /// comes up after boot). Returns true on success. Never throws to the caller.
    static func sendLine(udsPath: String, port: Int, line: String, deadline: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while true {
            if attempt(udsPath: udsPath, port: port, line: line) {
                return true
            }
            if Date() >= end {
                NSLog("IgnitionBrowser: VsockClient.sendLine timed out for \(udsPath) port \(port)")
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// One full connect + handshake + send. Returns true only on success; closes
    /// the fd on every path.
    private static func attempt(udsPath: String, port: Int, line: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }

        // Bound every read so a peer that accepts but never replies (or queues us
        // in the listen backlog without servicing) can't wedge the attempt — the
        // deadline loop in sendLine then retries or gives up.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(udsPath.utf8)
        // sun_path capacity (104 on Darwin); leave room for the NUL terminator.
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count >= capacity { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = b }
                dst[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 { return false }

        guard writeAll(fd, Array("CONNECT \(port)\n".utf8)) else { return false }

        // Read the ack line, capped at 128 bytes.
        var ack = [UInt8]()
        while ack.last != UInt8(ascii: "\n") {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            if n <= 0 { return false }      // peer closed before newline -> port not ready
            ack.append(byte)
            if ack.count > 128 { return false }
        }
        guard ack.starts(with: Array("OK ".utf8)) else { return false }

        // OK: send the URL line, ensuring exactly one trailing newline.
        let payload = line.hasSuffix("\n") ? line : line + "\n"
        return writeAll(fd, Array(payload.utf8))
    }

    /// Write the whole buffer, retrying on EINTR / partial writes.
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        return bytes.withUnsafeBytes { buf -> Bool in
            while offset < bytes.count {
                let n = write(fd, buf.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
