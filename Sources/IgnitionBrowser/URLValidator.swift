import Foundation

/// The one piece with real logic. Trims, parses, and accepts only http/https.
/// Everything else (file:, javascript:, ftp:, data:, empty, …) is rejected.
enum URLValidator {
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased() else { return nil }
        guard scheme == "http" || scheme == "https" else { return nil }
        // An http(s) URL must have a host.
        guard let host = components.host, !host.isEmpty else { return nil }

        return components.url
    }
}

#if DEBUG
// Cheap self-check at first use during dev builds; XCTest in Tests/ is the real coverage.
private let _urlValidatorSelfCheck: Void = {
    assert(URLValidator.normalize("https://example.com") != nil)
    assert(URLValidator.normalize("http://x") != nil)
    assert(URLValidator.normalize("javascript:alert(1)") == nil)
    assert(URLValidator.normalize("file:///etc/passwd") == nil)
    assert(URLValidator.normalize("") == nil)
    assert(URLValidator.normalize("ftp://x") == nil)
}()
#endif
