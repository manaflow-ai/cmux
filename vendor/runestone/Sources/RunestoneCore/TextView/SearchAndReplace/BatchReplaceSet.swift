import Foundation

/// Multiple ranges of the text in a text view to be replaced with a string.
///
/// When replacing text in batches, Runestone can do some optimizations to make the operation faster than when replacing the ranges one by one.
///
/// Replacing a batch of matches will only register a single undo operation.
///
/// All ranges should be provided relative to the current text in the text view.
public struct BatchReplaceSet: Hashable {
    /// A range of text to replace and the text to replace that range with.
    public struct Replacement: Hashable {
        /// The range of text in the text view to replace.
        public let range: NSRange
        /// The text to replace the text in the specified range with.
        public let text: String

        /// Creates a match to be replaced with the specified replacement text.
        /// - Parameters:
        ///   - range: The range of text in the text view to replace.
        ///   - text: The text to replace the text in the specified range with.
        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// All text matches to replace.
    public let replacements: [Replacement]

    /// Creates a set of ranges to replace with specified strings.
    /// - Parameter replacements: All ranges to replace in the text view and their corresponding replacement texts.
    public init(replacements: [Replacement]) {
        self.replacements = replacements
    }
}
