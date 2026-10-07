import Foundation

/// A typed query, prepared once per keystroke: the whole text and its
/// whitespace-separated tokens.
public struct SearchQuery: Hashable, Sendable {
    public let raw: String
    let whole: SearchText
    let tokens: [SearchText]

    public init(_ raw: String) {
        self.raw = raw
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        whole = SearchText(trimmed)
        tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map { SearchText(String($0)) }
    }

    public var isEmpty: Bool { tokens.isEmpty }
}
