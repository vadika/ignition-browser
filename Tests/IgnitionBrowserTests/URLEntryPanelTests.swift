import XCTest
@testable import IgnitionBrowser

final class URLEntryPanelTests: XCTestCase {
    func testValidClipboardURLIsNormalized() {
        // A valid http(s) URL is returned in canonical absoluteString form.
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: "https://example.com/path"),
                       "https://example.com/path")
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: "  http://x  "),
                       "http://x")
    }

    func testNonURLClipboardGivesEmpty() {
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: "just some text"), "")
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: "javascript:alert(1)"), "")
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: "file:///etc/passwd"), "")
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: nil), "")
        XCTAssertEqual(URLEntryPanel.initialText(clipboard: ""), "")
    }
}
