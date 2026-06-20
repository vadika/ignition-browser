import XCTest
@testable import IgnitionBrowser

final class URLValidatorTests: XCTestCase {
    func testAcceptsHTTPS() {
        XCTAssertNotNil(URLValidator.normalize("https://example.com"))
    }

    func testAcceptsHTTP() {
        XCTAssertNotNil(URLValidator.normalize("http://x"))
    }

    func testRejectsJavascript() {
        XCTAssertNil(URLValidator.normalize("javascript:alert(1)"))
    }

    func testRejectsFile() {
        XCTAssertNil(URLValidator.normalize("file:///etc/passwd"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(URLValidator.normalize(""))
    }

    func testRejectsFTP() {
        XCTAssertNil(URLValidator.normalize("ftp://x"))
    }
}
