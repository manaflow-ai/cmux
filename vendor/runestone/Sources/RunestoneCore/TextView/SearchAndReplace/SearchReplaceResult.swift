import Foundation

/// Contains information necessary to replace a range in the text view with a replacement text.
///
/// When the text view returns this result the text has not been replaced yet. It is up to the developer to use the range and replacement text in this result to replace the text in the text view, for example by calling ``TextView/replaceText(in:)``.
public struct SearchReplaceResult: Hashable, Equatable {
    /// Unique identifier of the result.
    public let id: String = UUID().uuidString
    /// Range of the matched text.
    public let range: NSRange
    /// Position at which the matched text starts.
    public let startLocation: TextLocation
    /// Position at which the matched text ends.
    public let endLocation: TextLocation
    /// Text to replace the match with.
    ///
    /// The replacement text is expanded to account for any capture groups referenced by the replacement text passed to ``TextView/search(for:replacingMatchesWith:)`` using $0, $1, $2 etc.
    public let replacementText: String

    /// Creates a search replacement result.
    /// - Parameters:
    ///   - range: Range of the matched text.
    ///   - startLocation: Location where the match starts.
    ///   - endLocation: Location where the match ends.
    ///   - replacementText: Text that should replace the match.
    public init(range: NSRange, startLocation: TextLocation, endLocation: TextLocation, replacementText: String) {
        self.range = range
        self.startLocation = startLocation
        self.endLocation = endLocation
        self.replacementText = replacementText
    }
}
