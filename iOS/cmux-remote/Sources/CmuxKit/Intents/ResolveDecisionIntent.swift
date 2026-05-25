import Foundation
public import AppIntents
import UserNotifications

/// `LiveActivityIntent` — runs in the **main app process** in the
/// background when the user taps a Live Activity button. No app launch.
/// This is the only Apple-blessed path for one-tap decision resolution
/// from the Lock Screen with dynamic button labels.
///
/// The intent lives in `CmuxKit` (not the app target) so the widget
/// extension's Live Activity widget can construct it without importing
/// the host app. The actual work is delegated to a closure the app
/// registers at launch via `CmuxIntentResolverRegistry`.
public struct ResolveDecisionIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Resolve cmux agent decision"
    public static let openAppWhenRun: Bool = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Decision id") public var decisionID: String
    @Parameter(title: "Item id") public var itemID: String?
    @Parameter(title: "Decision kind") public var decisionKind: String
    @Parameter(title: "Choice id") public var choiceID: String
    @Parameter(title: "Choice label") public var choiceLabel: String?
    @Parameter(title: "Question selections") public var questionSelectionsJSON: String?
    @Parameter(title: "Agent name") public var agentName: String?
    @Parameter(title: "Host id") public var hostID: String?
    @Parameter(title: "Workspace id") public var workspaceID: String?
    @Parameter(title: "Requires authentication") public var requiresAuth: Bool
    @Parameter(title: "Destructive choice") public var isDestructive: Bool

    public init() {}

    public init(
        decisionID: String,
        itemID: String?,
        decisionKind: String,
        choiceID: String,
        choiceLabel: String?,
        questionSelectionsJSON: String?,
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
        self.questionSelectionsJSON = questionSelectionsJSON
        self.agentName = agentName
        self.hostID = hostID
        self.workspaceID = workspaceID
        self.requiresAuth = requiresAuth
        self.isDestructive = isDestructive
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let itemID, !itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .result(dialog: IntentDialog(
                stringLiteral: String(
                    localized: "intent.resolve_decision.missing_item",
                    defaultValue: "This remote decision is missing its feed item. Open cmux to resolve it."
                )
            ))
        }
        let result = await CmuxIntentResolverRegistry.resolveDecision(.init(
            decisionID: decisionID,
            itemID: itemID.trimmingCharacters(in: .whitespacesAndNewlines),
            decisionKind: decisionKind,
            choiceID: choiceID,
            choiceLabel: choiceLabel,
            questionSelections: Self.decodeQuestionSelections(questionSelectionsJSON),
            agentName: agentName,
            hostID: hostID,
            workspaceID: workspaceID,
            requiresAuth: requiresAuth,
            isDestructive: isDestructive
        ))
        switch result {
        case .delivered:
            // Only remove the delivered notification AFTER the server has
            // acknowledged the decision. Dismissing before the ack risks
            // leaving the agent stuck while the user thinks they
            // resolved it.
            await MainActor.run {
                var identifiers = ["decision:\(decisionID)"]
                if let hostID {
                    identifiers.append("decision:\(AgentDecision.scopeKey(decisionID: decisionID, hostID: hostID))")
                }
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: identifiers
                )
                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: identifiers
                )
            }
            return .result(dialog: IntentDialog(
                stringLiteral: String(localized: "intent.resolve_decision.sent", defaultValue: "Sent.")
            ))
        case .noHandler:
            return .result(dialog: IntentDialog(
                stringLiteral: String(
                    localized: "intent.resolve_decision.not_connected",
                    defaultValue: "Not connected - open cmux to deliver this decision."
                )
            ))
        case .failed:
            let dialog = String(
                localized: "intent.resolve_decision.failed",
                defaultValue: "Couldn't deliver. Open cmux to check the connection."
            )
            return .result(dialog: IntentDialog(
                stringLiteral: dialog
            ))
        }
    }

    private static func decodeQuestionSelections(_ value: String?) -> [AgentDecision.QuestionSelection]? {
        guard let value,
              let data = value.data(using: .utf8),
              let selections = try? JSONDecoder().decode(
                [AgentDecision.QuestionSelection].self,
                from: data
              ),
              !selections.isEmpty else {
            return nil
        }
        return selections
    }
}
