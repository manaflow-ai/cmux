import Foundation

/// An `approve` prompt: what the agent wants to do and which scopes it offers.
public struct FeedPermission: Hashable, Sendable {
    public enum ActionType: String, Hashable, Sendable {
        case command, edit, tool, network, install, custom
    }

    public var actionType: ActionType
    public var summary: String
    public var command: String?
    public var cwd: String?
    public var tool: String?
    public var risk: String?
    /// Offered allow scopes, in the poster's order; empty means once only.
    public var scopes: [FeedPermissionScope]

    public init(actionType: ActionType, summary: String, command: String? = nil, cwd: String? = nil,
                tool: String? = nil, risk: String? = nil, scopes: [FeedPermissionScope] = [.once]) {
        self.actionType = actionType
        self.summary = summary
        self.command = command
        self.cwd = cwd
        self.tool = tool
        self.risk = risk
        self.scopes = scopes
    }

    /// The scopes the allow menu offers (at least `once`).
    public var offeredScopes: [FeedPermissionScope] { scopes.isEmpty ? [.once] : scopes }
}
