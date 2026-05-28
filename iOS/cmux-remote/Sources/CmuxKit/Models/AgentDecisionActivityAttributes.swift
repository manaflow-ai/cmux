import Foundation
public import ActivityKit

/// Live Activity attributes for a single agent decision. Distinct from
/// `CMUXActivityAttributes` (the long-lived host activity) so the dismissal
/// policies and update cadences can be independent.
public struct AgentDecisionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var summary: String
        public var detail: String?
        public var choices: [Choice]
        public var resolved: Bool
        public var resolvedChoice: String?

        public init(
            summary: String,
            detail: String?,
            choices: [Choice],
            resolved: Bool,
            resolvedChoice: String?
        ) {
            self.summary = summary
            self.detail = detail
            self.choices = choices
            self.resolved = resolved
            self.resolvedChoice = resolvedChoice
        }
    }

    public struct Choice: Codable, Hashable, Sendable {
        public let id: String
        public let label: String
        public let replyLabel: String?
        public let requiresAuth: Bool
        public let isDestructive: Bool
        public let isAffirmative: Bool
        public let questionSelections: [AgentDecision.QuestionSelection]?

        public init(
            id: String,
            label: String,
            replyLabel: String?,
            requiresAuth: Bool,
            isDestructive: Bool,
            isAffirmative: Bool,
            questionSelections: [AgentDecision.QuestionSelection]? = nil
        ) {
            self.id = id
            self.label = label
            self.replyLabel = replyLabel
            self.requiresAuth = requiresAuth
            self.isDestructive = isDestructive
            self.isAffirmative = isAffirmative
            self.questionSelections = questionSelections
        }
    }

    public let decisionID: String
    public let itemID: String?
    public let decisionKind: String
    public let agentName: String
    public let hostID: String?
    public let workspaceID: String?
    public let surfaceID: String?

    public init(
        decisionID: String,
        itemID: String?,
        decisionKind: String,
        agentName: String,
        hostID: String?,
        workspaceID: String?,
        surfaceID: String?
    ) {
        self.decisionID = decisionID
        self.itemID = itemID
        self.decisionKind = decisionKind
        self.agentName = agentName
        self.hostID = hostID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }
}
