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
