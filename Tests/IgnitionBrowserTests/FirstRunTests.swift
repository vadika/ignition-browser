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
