import Foundation

/// What an agent asks for. Each kind maps to inline reply controls.
public enum FeedItemKind: Hashable, Sendable {
    case permission
    /// `options` are the agent's offered choices; empty means free text.
    case question(options: [String])
    case planApproval
    case done
}
