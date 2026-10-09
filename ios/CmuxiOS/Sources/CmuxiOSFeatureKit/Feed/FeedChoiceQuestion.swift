import Foundation

public struct FeedChoiceQuestion: Identifiable, Hashable, Sendable {
    public var id: String
    public var question: String
    public var header: String?
    public var options: [FeedChoiceOption]
    public var multi: Bool
    public var allowOther: Bool

    public init(id: String, question: String, header: String? = nil, options: [FeedChoiceOption],
                multi: Bool = false, allowOther: Bool = false) {
        self.id = id
        self.question = question
        self.header = header
        self.options = options
        self.multi = multi
        self.allowOther = allowOther
    }
}
