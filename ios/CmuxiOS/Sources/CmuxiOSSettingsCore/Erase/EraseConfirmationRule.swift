import Foundation

/// The typed confirmation before Erase All Data: the localized word,
/// ignoring surrounding spaces, case and character width.
public struct EraseConfirmationRule: Hashable, Sendable {
    public let word: String

    public init(word: String) {
        self.word = word
    }

    public func matches(_ typed: String) -> Bool {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !trimmed.isEmpty else { return false }
        return trimmed.compare(word, options: [.caseInsensitive, .widthInsensitive], range: nil, locale: nil) == .orderedSame
    }
}
