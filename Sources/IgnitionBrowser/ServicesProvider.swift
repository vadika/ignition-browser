import AppKit

/// Backs the macOS Services menu entry "Open in Ignition Browser".
/// The pasteboard string is attacker-controlled: we validate + normalize it
/// host-side and hand the result to the session by a typed channel — never a shell.
final class ServicesProvider: NSObject {
    private let sessions: SessionManager

    init(sessions: SessionManager) {
        self.sessions = sessions
    }

    @objc func openInIgnitionBrowser(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        // Try a typed URL first, then fall back to plain text.
        let raw = pboard.string(forType: .URL) ?? pboard.string(forType: .string)
        guard let raw else {
            error.pointee = "No text found on the pasteboard." as NSString
            return
        }
        guard let url = URLValidator.normalize(raw) else {
            error.pointee = "Not a valid http/https URL." as NSString
            return
        }
        sessions.openSession(url: url)
    }
}
