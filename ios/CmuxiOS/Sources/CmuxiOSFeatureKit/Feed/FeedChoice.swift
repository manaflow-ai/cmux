import Foundation

/// A `choice` prompt: one to four questions answered together.
public struct FeedChoice: Hashable, Sendable {
    public var questions: [FeedChoiceQuestion]

    public init(questions: [FeedChoiceQuestion]) { self.questions = questions }

    /// True when every question has at least one pick or an "other" text.
    public func isComplete(_ answers: [String: FeedChoiceSelection]) -> Bool {
        !questions.isEmpty && questions.allSatisfy { answers[$0.id]?.isEmpty == false }
    }
}
