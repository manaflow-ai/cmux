/// A Mac path as one POSIX single-quoted shell token (parity with the
/// shipping `TerminalComposerAttachmentInsertion`).
public struct ShellQuotedPath: Hashable, Sendable {
    public let path: String

    public init(_ path: String) {
        self.path = path
    }

    /// `'…'` with interior quotes as `'\''`.
    public var token: String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What a terminal paste inserts: the token and one trailing space.
    public var pasteText: String { token + " " }
}
