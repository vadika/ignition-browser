import XCTest
import Darwin
@testable import IgnitionBrowser

/// A tiny AF_UNIX listener that mimics boot+guest for the vsock URL channel:
/// accept, read the `CONNECT <port>\n` line, reply (or not), then read the next
/// line (the URL) and record it. Each instance binds one temp path and serves
/// exactly one connection on a background thread.
private final class FakeVsockServer: @unchecked Sendable {
    let path: String
    private let listenFd: Int32
    private let respondOK: Bool

    /// Captured by the server thread.
    private(set) var connectLine = ""
    private(set) var urlLine = ""
    let done = DispatchSemaphore(value: 0)

    init?(respondOK: Bool) {
        self.respondOK = respondOK
        self.path = NSTemporaryDirectory()
            + "vsocktest-\(UUID().uuidString.prefix(8)).sock"

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        if listenFd < 0 { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { close(listenFd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
                dst[bytes.count] = 0
            }
        }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bound != 0 { close(listenFd); return nil }
        if listen(listenFd, 1) != 0 { close(listenFd); return nil }
    }

    func start() {
        DispatchQueue.global().async { [self] in
            let conn = accept(listenFd, nil, nil)
            if conn < 0 { done.signal(); return }
            defer { close(conn); done.signal() }

            connectLine = readLine(conn)
            guard respondOK else { return }     // hang up without OK
            _ = writeAll(conn, "OK 1\n")
            urlLine = readLine(conn)
        }
    }

    func stop() {
        close(listenFd)
        unlink(path)
    }

    private func readLine(_ fd: Int32) -> String {
        var bytes = [UInt8]()
        while bytes.last != UInt8(ascii: "\n") {
            var b: UInt8 = 0
            let n = read(fd, &b, 1)
            if n <= 0 { break }
            bytes.append(b)
            if bytes.count > 4096 { break }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeAll(_ fd: Int32, _ s: String) -> Bool {
        let bytes = Array(s.utf8)
        var off = 0
        return bytes.withUnsafeBytes { buf in
            while off < bytes.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), bytes.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}

final class VsockClientTests: XCTestCase {
    func testSendsURLAfterHandshake() throws {
        let server = try XCTUnwrap(FakeVsockServer(respondOK: true))
        defer { server.stop() }
        server.start()

        let ok = VsockClient.sendLine(
            udsPath: server.path, port: 7777,
            line: "https://example.com", deadline: 5)

        XCTAssertTrue(ok, "sendLine should succeed against an OK server")
        XCTAssertEqual(server.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(server.connectLine, "CONNECT 7777\n")
        XCTAssertEqual(server.urlLine, "https://example.com\n")
    }

    func testFailsWhenServerClosesWithoutOK() throws {
        let server = try XCTUnwrap(FakeVsockServer(respondOK: false))
        defer { server.stop() }
        server.start()

        let ok = VsockClient.sendLine(
            udsPath: server.path, port: 7777,
            line: "https://example.com", deadline: 1.5)

        XCTAssertFalse(ok, "sendLine should fail by the deadline when no OK arrives")
    }
}
