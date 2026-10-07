/// A prompt ready for the terminal: one paste (bracketed when the program
/// asked for it) and, unless inserting only, one Return (e4-compose.md 2).
public struct ComposerSubmission: Hashable, Sendable {
    public var text: String
    public var submits: Bool

    /// The draft normalized for a paste, or nil when nothing is left: CRLF
    /// and CR become LF; control characters other than LF and TAB (C0, DEL,
    /// C1) are removed, so an ESC can never end a bracketed paste early;
    /// leading blank lines and trailing whitespace are trimmed.
    public init?(draft: String, submits: Bool = true) {
        let unified = draft.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in unified.unicodeScalars where Self.keeps(scalar) { scalars.append(scalar) }
        var lines = String(scalars).split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.allSatisfy({ $0 == " " || $0 == "\t" }) { lines.removeFirst() }
        var text = lines.joined(separator: "\n")
        while let last = text.last, last.isWhitespace { text.removeLast() }
        guard !text.isEmpty else { return nil }
        self.text = text
        self.submits = submits
    }

    public var isMultiline: Bool { text.contains("\n") }

    private static func keeps(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: true
        case 0x00...0x1F, 0x7F, 0x80...0x9F: false
        default: true
        }
    }
}
