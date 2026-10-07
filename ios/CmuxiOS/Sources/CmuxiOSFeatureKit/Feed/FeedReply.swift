import Foundation

/// An inline answer to a request, one shape per answerable kind (the kind's
/// answer schema, feed.md 3.4).
public enum FeedReply: Hashable, Sendable {
    /// `approve`: allow (with a scope) or deny.
    case permission(allow: Bool, scope: FeedPermissionScope?)
    /// `question`.
    case text(String)
    /// `choice`: selections by question id.
    case choice([String: FeedChoiceSelection])
    /// `review` of a plan: approve, or request changes with a comment.
    case plan(approved: Bool, comment: String?)
    /// `confirm`.
    case confirm(Bool)

    /// Whether this reply fits `kind` (the owner validates again).
    public func fits(_ kind: FeedItemKind) -> Bool {
        switch (self, kind) {
        case (.permission(let allow, let scope), .permission(let prompt)):
            guard allow, let scope else { return true }
            return prompt.offeredScopes.contains(scope)
        case (.text(let text), .question):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case (.choice(let answers), .choice(let prompt)):
            return prompt.isComplete(answers)
        case (.plan, .planApproval), (.confirm, .confirm):
            return true
        default:
            return false
        }
    }
}
