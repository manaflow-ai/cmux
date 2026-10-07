import Foundation

/// A completion trigger under the cursor: `/name` at the start of a line
/// (templates) or `@path` after whitespace (file mentions).
public struct PromptTrigger: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case template
        case mention
    }

    public var kind: Kind
    /// UTF-16 range of the trigger including its `/` or `@`.
    public var range: NSRange
    /// The text after the trigger character up to the cursor.
    public var query: String

    public init(kind: Kind, range: NSRange, query: String) {
        self.kind = kind
        self.range = range
        self.query = query
    }

    /// The trigger ending at `cursor` (a UTF-16 offset), if any: the word
    /// before the cursor starts with `/` at a line start or with `@`.
    public init?(text: String, cursor: Int) {
        let utf16 = Array(text.utf16)
        guard cursor > 0, cursor <= utf16.count else { return nil }
        var start = cursor
        while start > 0, !Self.isSpace(utf16[start - 1]) { start -= 1 }
        guard start < cursor, cursor - start <= 65 else { return nil }
        let marker = utf16[start]
        let atLineStart = start == 0 || utf16[start - 1] == 0x0A
        let query = String(decoding: utf16[(start + 1)..<cursor], as: UTF16.self)
        let range = NSRange(location: start, length: cursor - start)
        if marker == 0x2F, atLineStart, !query.contains("/") {
            self.init(kind: .template, range: range, query: query)
        } else if marker == 0x40, !query.contains("@") {
            self.init(kind: .mention, range: range, query: query)
        } else {
            return nil
        }
    }

    /// `text` with the trigger replaced by `replacement`, and the cursor after it.
    public func applying(_ replacement: String, to text: String) -> (text: String, cursor: Int) {
        let source = text as NSString
        guard NSMaxRange(range) <= source.length else { return (text, source.length) }
        let next = source.replacingCharacters(in: range, with: replacement)
        return (next, range.location + (replacement as NSString).length)
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
    }
}
