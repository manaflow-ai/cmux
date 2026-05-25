import Foundation
import UserNotifications
import CmuxKit
import Logging

/// Builds the notification representation of an `AgentDecision`.
///
/// Strategy per `docs/known-limitations.md` and the in-tree notification
/// research:
///
/// 1. Pre-register N-choice category templates with anonymous action IDs
///    (`A`, `B`, `C`, `D`).
/// 2. Re-register the category set right before posting so the generic
///    actions exist in the system's registered set.
/// 3. Encode only opaque choice ids / styles into `userInfo["choices"]`.
///    Visible Lock Screen text stays anonymous ("A: Option A") and the
///    payload at rest does not include server-provided labels.
/// 4. When the user taps an action, look up the matching choice id and resolve
///    via the typed feed RPC methods in `AgentDecisionResolver`.
@MainActor
enum AgentDecisionNotifier {

    static let categoryPrefix = "CMUX_DECISION_"
    static let destructiveSuffix = "_DESTRUCTIVE"
    private static let unboundCategoryID = "CMUX_DECISION_UNBOUND"

    static func reRegisterCategories(for decisions: [AgentDecision]) async {
        // Each decision gets its OWN category whose action ids and
        // options are derived from that decision's choices: action `A`
        // / `B` / `C` / `D` plus `.destructive` and
        // `.authenticationRequired` if the matching choice carries
        // `style == .destructive` or `requiresAuth == true`. This
        // honours per-choice auth (CRIT raised by Codex) instead of
        // pretending all-or-nothing.
        var categories: Set<UNNotificationCategory> = []
        for decision in decisions {
            categories.insert(makeCategory(for: decision))
        }
        let existing = await UNUserNotificationCenter.current().notificationCategories()
        let merged = existing.union(categories)
        UNUserNotificationCenter.current().setNotificationCategories(merged)
    }

    static func makeRequest(for decision: AgentDecision) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = genericDecisionTitle()
        content.subtitle = L10n.string(
            "decision.notification.subtitle",
            defaultValue: "Agent is waiting for approval"
        )
        content.body = composedBody(for: decision)
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1.0
        content.threadIdentifier = decision.workspaceID.map { "workspace:\($0.raw)" } ?? "cmux-decision"
        content.categoryIdentifier = categoryID(for: decision)
        content.userInfo = userInfo(for: decision)
        return UNNotificationRequest(
            identifier: "decision:\(decision.scopeKey)",
            content: content,
            trigger: nil
        )
    }

    static func userInfo(for decision: AgentDecision) -> [AnyHashable: Any] {
        let choices = actionChoices(for: decision)
        var userInfo: [AnyHashable: Any] = [
            "kind": "agent_decision",
            "decision_id": decision.id,
            "decision_kind": decision.kind.rawValue,
            "agent_name": genericAgentName(),
            "choices": choices.map { choice in
                [
                    "id": choice.id,
                    "style": choice.style.rawValue,
                    "requires_auth": choice.requiresAuth,
                    "question_selections": questionSelectionsPayload(choice.questionSelections)
                ]
            }
        ]
        if let hostID = decision.hostID {
            userInfo["host_id"] = hostID.uuidString
        }
        if let itemID = decision.itemID {
            userInfo["item_id"] = itemID
        }
        if let workspaceID = decision.workspaceID?.raw {
            userInfo["workspace_id"] = workspaceID
        }
        if let surfaceID = decision.surfaceID?.raw {
            userInfo["surface_id"] = surfaceID
        }
        return userInfo
    }

    static func composedBody(for decision: AgentDecision) -> String {
        // Critical privacy invariant: do NOT include `decision.detail`
        // (raw command, diff snippet, tool input) in the Lock Screen body.
        // Detail can contain secrets, file paths, env vars. The user
        // unlocks + opens the app to see the redacted content. Choice
        // labels may also be server-provided question text, so the Lock
        // Screen banner only shows anonymous choice keys.
        let prefixes = ["A", "B", "C", "D"]
        return actionChoices(for: decision).enumerated()
            .map { idx, _ in "\(prefixes[idx]): \(optionTitle(for: prefixes[idx]))" }
            .joined(separator: "    ")
    }

    static func categoryID(for decision: AgentDecision) -> String {
        guard decision.hasBoundFeedItem else { return unboundCategoryID }
        // Encode the per-choice auth/destructive flags in the category id
        // so that two decisions with the same shape (e.g. "Yes/No, both
        // safe") share a category and we don't blow past UN's category
        // registration cap (~100 in practice).
        let choices = actionChoices(for: decision)
        let signature = choices.map { choice -> String in
            var s = ""
            if choice.requiresAuth { s += "a" }
            if choice.style == .destructive { s += "d" }
            if s.isEmpty { s = "_" }
            return s
        }.joined(separator: "-")
        return "\(categoryPrefix)\(choices.count)__\(signature)"
    }

    static func makeCategory(for decision: AgentDecision) -> UNNotificationCategory {
        guard decision.hasBoundFeedItem else {
            return UNNotificationCategory(
                identifier: unboundCategoryID,
                actions: [],
                intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: L10n.string(
                    "decision.notification.hidden_preview",
                    defaultValue: "Agent is waiting on your approval"
                ),
                options: [.customDismissAction]
            )
        }
        let ids = ["A", "B", "C", "D"]
        let pairs = Array(zip(ids, actionChoices(for: decision)))
        let actions: [UNNotificationAction] = pairs.map { id, choice in
            var options: UNNotificationActionOptions = []
            if choice.style == .destructive {
                options.insert(.destructive)
            }
            if requiresAuthentication(for: choice) {
                // Always require unlock on a destructive choice so a
                // glanceable Lock Screen tap can't commit damage.
                options.insert(.authenticationRequired)
            }
            return UNNotificationAction(
                identifier: id,
                title: optionTitle(for: id),
                options: options
            )
        }
        return UNNotificationCategory(
            identifier: categoryID(for: decision),
            actions: actions,
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: L10n.string(
                "decision.notification.hidden_preview",
                defaultValue: "Agent is waiting on your approval"
            ),
            options: [.customDismissAction]
        )
    }

    private static func actionChoices(for decision: AgentDecision) -> [AgentDecision.Choice] {
        let limit = 4
        if decision.choices.count <= limit { return decision.choices }
        var choices = Array(decision.choices.prefix(limit))
        if !choices.contains(where: { $0.style == .destructive }),
           let destructive = decision.choices.first(where: { $0.style == .destructive }) {
            choices[limit - 1] = destructive
        }
        return choices
    }

    private static func requiresAuthentication(for choice: AgentDecision.Choice) -> Bool {
        if choice.requiresAuth || choice.style == .destructive { return true }
        // Remote notification actions resolve a pending agent decision on
        // the user's Mac. Treat every non-denial as privileged even when
        // older payloads forgot to set requiresAuth.
        return !["deny", "reject"].contains(choice.id)
    }

    private static func questionSelectionsPayload(
        _ selections: [AgentDecision.QuestionSelection]?
    ) -> [[String: Any]] {
        guard let selections else { return [] }
        return selections.map { selection in
            [
                "question_id": selection.questionID,
                "option_ids": selection.optionIDs
            ]
        }
    }

    static func optionTitle(for id: String) -> String {
        L10n.format("decision.notification.option", defaultValue: "Option %@", id)
    }

    private static func genericDecisionTitle() -> String {
        L10n.string("decision.notification.title", defaultValue: "cmux decision")
    }

    private static func genericAgentName() -> String {
        L10n.string("decision.agent.generic", defaultValue: "cmux agent")
    }

    /// Resolves the user's tap on action identifier `actionID` for the
    /// notification carrying `userInfo` produced by `makeRequest(for:)`.
    static func handleAction(
        actionID: String,
        userInfo: [AnyHashable: Any]
    ) async {
        let log = CmuxLog.make("notifications.agent")
        guard let decisionID = userInfo["decision_id"] as? String else {
            log.error("decision action missing decision_id")
            await postActionFailure(
                decisionID: nil,
                message: L10n.string(
                    "decision.notification.error.malformed",
                    defaultValue: "Could not resolve the decision because the notification payload was invalid."
                )
            )
            return
        }
        guard let rawChoices = userInfo["choices"] as? [[String: Any]] else {
            log.error("decision action missing choices", metadata: ["decision_id": .string(decisionID)])
            await postActionFailure(
                decisionID: decisionID,
                message: L10n.string(
                    "decision.notification.error.malformed",
                    defaultValue: "Could not resolve the decision because the notification payload was invalid."
                )
            )
            return
        }

        let prefixes = ["A", "B", "C", "D"]
        guard let idx = prefixes.firstIndex(of: actionID),
              idx < rawChoices.count,
              let choiceID = rawChoices[idx]["id"] as? String else {
            log.error("decision action choice mismatch", metadata: [
                "decision_id": .string(decisionID),
                "action_id": .string(actionID)
            ])
            await postActionFailure(
                decisionID: decisionID,
                message: L10n.string(
                    "decision.notification.error.choice_mismatch",
                    defaultValue: "Could not match that notification action to a cmux decision choice."
                )
            )
            return
        }
        guard let decisionKind = userInfo["decision_kind"] as? String,
              let kind = AgentDecision.Kind(rawValue: decisionKind) else {
            log.error("decision action unknown kind", metadata: [
                "decision_id": .string(decisionID),
                "decision_kind": .string(String(describing: userInfo["decision_kind"]))
            ])
            await postActionFailure(
                decisionID: decisionID,
                message: L10n.string(
                    "decision.notification.error.unknown_kind",
                    defaultValue: "This decision type is not supported by this version of cmux-remote. Open cmux on your Mac to resolve it."
                )
            )
            return
        }
        let choiceLabel = rawChoices[idx]["label"] as? String
        guard let itemID = userInfo["item_id"] as? String,
              !itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.error("decision action missing item_id", metadata: [
                "decision_id": .string(decisionID)
            ])
            await postActionFailure(
                decisionID: decisionID,
                message: L10n.string(
                    "decision.notification.error.unbound_item",
                    defaultValue: "cmux-remote could not verify the exact feed item for this decision. Open the app or cmux on your Mac to resolve it."
                )
            )
            return
        }
        let questionSelections = parseQuestionSelections(rawChoices[idx]["question_selections"])
        let hostID = (userInfo["host_id"] as? String).flatMap(UUID.init(uuidString:))

        do {
            try await ConnectionManager.shared.resolveAgentDecision(
                decisionID: decisionID,
                hostID: hostID,
                itemID: itemID,
                kind: kind,
                choiceID: choiceID,
                choiceLabel: choiceLabel,
                questionSelections: questionSelections
            )
            await NotificationCenterBridge.shared.clearAgentDecision(decisionID: decisionID, hostID: hostID)
        } catch {
            log.error("decision resolve failed: \(error.localizedDescription)")
            NotificationCenterBridge.shared.markAgentDecisionDeliveryFailed(
                decisionID: decisionID,
                hostID: hostID
            )
            await postActionFailure(
                decisionID: decisionID,
                message: L10n.string(
                    "decision.notification.error.resolve_failed",
                    defaultValue: "cmux could not resolve that decision. Open the app and try again."
                )
            )
        }
    }

    private static func parseQuestionSelections(_ raw: Any?) -> [AgentDecision.QuestionSelection]? {
        guard let rawSelections = raw as? [[String: Any]], !rawSelections.isEmpty else {
            return nil
        }
        let selections = rawSelections.compactMap { entry -> AgentDecision.QuestionSelection? in
            guard let questionID = entry["question_id"] as? String,
                  let optionIDs = entry["option_ids"] as? [String],
                  !questionID.isEmpty,
                  !optionIDs.isEmpty else {
                return nil
            }
            return AgentDecision.QuestionSelection(questionID: questionID, optionIDs: optionIDs)
        }
        return selections.count == rawSelections.count ? selections : nil
    }

    private static func postActionFailure(decisionID: String?, message: String) async {
        let content = UNMutableNotificationContent()
        content.title = L10n.string("decision.notification.error.title", defaultValue: "Decision not delivered")
        content.body = message
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "cmux-decision-error"
        let suffix = decisionID ?? UUID().uuidString
        let request = UNNotificationRequest(
            identifier: "decision-error:\(suffix)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
