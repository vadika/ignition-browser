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
        // A manifest alone is no longer enough: the guest stamp must match too, so a
        // base built by a previous app version (different assets) is rebuilt.
        XCTAssertFalse(FirstRun.isComplete(cfg))
        try Data(FirstRun.guestStamp(cfg).utf8).write(to: snap.appendingPathComponent(".guest-stamp"))
        XCTAssertTrue(FirstRun.isComplete(cfg))
        // A mismatched stamp (assets changed) must read as incomplete.
        try Data("stale".utf8).write(to: snap.appendingPathComponent(".guest-stamp"))
        XCTAssertFalse(FirstRun.isComplete(cfg))
    }
}
