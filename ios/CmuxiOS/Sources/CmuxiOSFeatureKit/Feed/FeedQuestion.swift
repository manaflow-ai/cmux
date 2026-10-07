import Foundation

public struct FeedQuestion: Hashable, Sendable {
    public var question: String
    /// Up to 8 quick answers the poster suggests.
    public var suggestions: [String]
    public var multiline: Bool

    public init(question: String, suggestions: [String] = [], multiline: Bool = false) {
        self.question = question
        self.suggestions = suggestions
        self.multiline = multiline
    }
}
