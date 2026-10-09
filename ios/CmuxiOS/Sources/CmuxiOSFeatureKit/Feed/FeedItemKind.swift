import Foundation

/// What an item asks for (feed.md 3.4), reduced to what the phone renders.
/// Each answerable kind maps to inline controls; the rest are read-only.
public enum FeedItemKind: Hashable, Sendable {
    /// `approve`: a permission prompt.
    case permission(FeedPermission)
    /// `question`: free text, with optional suggestions.
    case question(FeedQuestion)
    /// `choice`: one to four multiple-choice questions.
    case choice(FeedChoice)
    /// `review` with subject `plan`.
    case planApproval(FeedPlan)
    /// `confirm`: yes or no.
    case confirm(FeedConfirm)
    /// `notice`: an agent finished or reported something; `body` is the summary.
    case done
    /// A kind the phone cannot answer (`sign-in`, `passkey`, `handoff`,
    /// `input`, `file`, other reviews, custom kinds). `needsMac` kinds can
    /// only be answered on the Mac that holds their context.
    case unsupported(kind: String, needsMac: Bool)

    public var isRequest: Bool {
        if case .done = self { return false }
        return true
    }

    public var isAnswerableOnPhone: Bool {
        switch self {
        case .permission, .question, .choice, .planApproval, .confirm: true
        case .done, .unsupported: false
        }
    }

    /// The owner's kind name.
    public var wireKind: String {
        switch self {
        case .permission: "approve"
        case .question: "question"
        case .choice: "choice"
        case .planApproval: "review"
        case .confirm: "confirm"
        case .done: "notice"
        case .unsupported(let kind, _): kind
        }
    }
}
