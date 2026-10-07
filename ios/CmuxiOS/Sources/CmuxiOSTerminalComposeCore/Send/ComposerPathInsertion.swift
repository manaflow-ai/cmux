/// An uploaded file's Mac path as a token in the draft: POSIX single quoted
/// (a quote inside becomes `'\''`), bare when every character is safe, and
/// separated from the surrounding text by single spaces (parity with the
/// shipping composer and C4's terminal paste).
public struct ComposerPathInsertion: Hashable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public var quoted: String {
        let safe: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:@%~")
        if !path.isEmpty, path.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `text` with the token inserted at the UTF-16 `offset` (clamped),
    /// and the caret offset just after the token's trailing space.
    public func inserting(into text: String, atUTF16Offset offset: Int) -> (text: String, caret: Int) {
        // Snap to the character boundary at or before the offset.
        var split = text.startIndex
        var consumed = 0
        for index in text.indices {
            let width = String(text[index]).utf16.count
            if consumed + width > offset { break }
            consumed += width
            split = text.index(after: index)
        }
        let before = text[..<split]
        let after = text[split...]
        let lead = before.isEmpty || before.last?.isWhitespace == true ? "" : " "
        let trail = after.first?.isWhitespace == true ? "" : " "
        let token = lead + quoted + trail
        let result = String(before) + token + String(after)
        let caret = before.utf16.count + token.utf16.count + (trail.isEmpty ? 1 : 0)
        return (result, min(caret, result.utf16.count))
    }
}
