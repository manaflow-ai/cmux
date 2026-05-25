import Foundation

/// Cross-target bridge so `ResolveDecisionIntent` (which is shared between
/// the app and the widget extension) can dispatch into the app-only
/// `ConnectionManager` without forcing the widget extension to import the
/// app module.
///
/// At app launch we register a Sendable closure that handles a decision
/// resolve. When the widget extension fires `ResolveDecisionIntent`,
/// AppIntents loads the SAME process and finds the registered closure.
public enum CmuxIntentResolverRegistry {
    public enum Result: Sendable {
        case noHandler
        case delivered
        case failed(message: String)
    }

    public struct DecisionResolveRequest: Sendable {
        public let decisionID: String
        public let itemID: String?
        public let decisionKind: String
        public let choiceID: String
        public let choiceLabel: String?
        public let questionSelections: [AgentDecision.QuestionSelection]?
        public let agentName: String?
        public let hostID: String?
        public let workspaceID: String?
        public let requiresAuth: Bool
        public let isDestructive: Bool

        public init(
            decisionID: String,
            itemID: String?,
            decisionKind: String,
            choiceID: String,
            choiceLabel: String?,
            questionSelections: [AgentDecision.QuestionSelection]?,
            agentName: String?,
            hostID: String?,
            workspaceID: String?,
            requiresAuth: Bool,
            isDestructive: Bool
        ) {
            self.decisionID = decisionID
            self.itemID = itemID
            self.decisionKind = decisionKind
            self.choiceID = choiceID
            self.choiceLabel = choiceLabel
            self.questionSelections = questionSelections
            self.agentName = agentName
            self.hostID = hostID
            self.workspaceID = workspaceID
            self.requiresAuth = requiresAuth
            self.isDestructive = isDestructive
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _resolveDecision: (@Sendable (
        _ request: DecisionResolveRequest
    ) async -> Result)?

    public static func registerResolveDecision(
        _ handler: @escaping @Sendable (DecisionResolveRequest) async -> Result
    ) {
        lock.lock(); defer { lock.unlock() }
        _resolveDecision = handler
    }

    public static func resolveDecision(_ request: DecisionResolveRequest) async -> Result {
        let handler: (@Sendable (DecisionResolveRequest) async -> Result)? = {
            lock.lock(); defer { lock.unlock() }
            return _resolveDecision
        }()
        guard let handler else { return .noHandler }
        return await handler(request)
    }
}
