import Foundation
import UserNotifications
import Intents
import CmuxKit
import Logging
import Combine
import UIKit
import Collections

/// Bridges between the cmux event stream and `UNUserNotificationCenter`.
///
/// On every snapshot change we diff the notification set against what we've
/// already delivered, schedule new ones, and cancel ones that have been
/// dismissed remotely. Notification identifiers are the cmux notification id
/// so `add(_:)` is idempotent and lossless across reconnects.
@MainActor
final class NotificationCenterBridge: NSObject, ObservableObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterBridge()

    private let log = CmuxLog.make("notifications.bridge")
    private var delivered: Set<NotificationID> = []
    private var delivering: Set<NotificationID> = []
    private var lastSnapshotIDs: Set<NotificationID> = []

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound, .providesAppNotificationSettings]
            )
            log.info("notification authorization granted=\(granted)")
        } catch {
            log.warning("notification auth error: \(error.localizedDescription)")
        }
    }

    private var deliveredDecisions: Set<String> = []
    private var pendingDecisions: [String: AgentDecision] = [:]

    func observeAgentDecision(
        _ decision: AgentDecision,
        resolverClient: CMUXClient? = nil
    ) async throws {
        let decisionKey = decision.scopeKey
        let previous = pendingDecisions[decisionKey]
        let decisionChanged = previous.map { Self.decisionSignature($0) != Self.decisionSignature(decision) } ?? false
        pendingDecisions[decisionKey] = decision
        if decisionChanged {
            deliveredDecisions.remove(decisionKey)
            let center = UNUserNotificationCenter.current()
            let identifiers = await decisionNotificationIdentifiers(
                decisionID: decision.id,
                hostID: decision.hostID,
                center: center
            )
            center.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
            center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
            await CMUXLiveActivityController.shared.endDecisionActivity(
                decisionID: decision.id,
                hostID: decision.hostID
            )
        }
        if deliveredDecisions.contains(decisionKey) { return }

        guard decision.hasBoundFeedItem else {
            log.warning("decision missing item_id; posting non-actionable notice", metadata: [
                "decision_id": .string(decision.id),
                "kind": .string(decision.kind.rawValue)
            ])
            await postUnboundDecisionNotice(decision)
            return
        }

        let center = UNUserNotificationCenter.current()
        let unboundIdentifiers = await unboundDecisionNotificationIdentifiers(
            decisionID: decision.id,
            hostID: decision.hostID,
            center: center
        )
        center.removeDeliveredNotifications(withIdentifiers: Array(unboundIdentifiers))
        center.removePendingNotificationRequests(withIdentifiers: Array(unboundIdentifiers))
        if await isDecisionNotificationPresent(
            decisionID: decision.id,
            hostID: decision.hostID,
            center: center
        ) {
            deliveredDecisions.insert(decisionKey)
            return
        }

        // Apply the user's AFK policy (if any). Auto-approve / auto-deny
        // rules can resolve a decision without ever surfacing to the user.
        let policy = AFKPolicyStore.shared.policy
        let evaluator = AFKPolicyEvaluator(policy: policy)
        let outcome = evaluator.evaluate(decision)
        switch outcome {
        case .autoApprove(let choiceID, let ruleLabel),
             .autoDeny(let choiceID, let ruleLabel):
            // Refuse to auto-approve a decision that has a destructive
            // choice when the policy demands biometric confirmation.
            // Auto-deny remains safe to apply without prompting.
            let chosenIsDestructive = decision.choices.first(where: { $0.id == choiceID })?.style == .destructive
            if case .autoApprove = outcome,
               (decision.hasDestructiveChoice || chosenIsDestructive)
                && policy.requireBiometricForDestructive {
                self.log.info("AFK auto-resolve declined: destructive + biometric required", metadata: [
                    "rule": .string(ruleLabel)
                ])
                break
            }
            do {
                if let client = resolverClient {
                    _ = try await client.resolveAgentDecision(
                        decision: decision,
                        choiceID: choiceID
                    )
                } else {
                    let selectedChoice = decision.choices.first(where: { $0.id == choiceID })
                    try await ConnectionManager.shared.resolveAgentDecision(
                        decisionID: decision.id,
                        hostID: decision.hostID,
                        itemID: decision.itemID,
                        kind: decision.kind,
                        choiceID: choiceID,
                        choiceLabel: selectedChoice?.label,
                        questionSelections: selectedChoice?.questionSelections
                    )
                }
                self.log.info("AFK auto-resolved", metadata: [
                    "rule": .string(ruleLabel),
                    "choice": .string(choiceID)
                ])
                deliveredDecisions.insert(decisionKey)
                await clearAgentDecision(decisionID: decision.id, hostID: decision.hostID)
                // Post an *informational* notification so the user knows
                // we auto-handled it.
                let content = UNMutableNotificationContent()
                content.title = L10n.format(
                    "notifications.auto_resolved.title",
                    defaultValue: "Auto-resolved: %@",
                    ruleLabel
                )
                content.body = L10n.string(
                    "notifications.auto_resolved.body",
                    defaultValue: "An AFK rule handled a cmux decision."
                )
                content.threadIdentifier = decision.workspaceID.map { "workspace:\($0.raw)" } ?? "cmux"
                content.interruptionLevel = .passive
                let req = UNNotificationRequest(
                    identifier: "auto-resolved:\(decision.scopeKey)",
                    content: content,
                    trigger: nil
                )
                try? await UNUserNotificationCenter.current().add(req)
                return
            } catch {
                if Self.isAlreadyResolvedDecisionError(error) {
                    await clearAgentDecision(decisionID: decision.id, hostID: decision.hostID)
                    return
                }
                log.warning("AFK auto-resolve failed; surfacing manual prompt", metadata: [
                    "error": .string(error.localizedDescription),
                    "rule": .string(ruleLabel)
                ])
            }
            // Fall through to the manual-prompt path when the destructive
            // + biometric guard fired, the client is unavailable, or the
            // remote resolve failed.
        case .ask:
            break
        }

        await AgentDecisionNotifier.reRegisterCategories(for: [decision])
        let request = AgentDecisionNotifier.makeRequest(for: decision)
        do {
            try await UNUserNotificationCenter.current().add(request)
            deliveredDecisions.insert(decisionKey)
        } catch {
            log.warning("decision notification add failed", metadata: [
                "decision_id": .string(decision.id),
                "error": .string(error.localizedDescription)
            ])
            throw error
        }
        await CMUXLiveActivityController.shared.presentDecision(decision)
    }

    func snoozeDecision(_ decisionID: String, hostID: UUID? = nil, by minutes: Int) {
        let keys = decisionKeys(decisionID: decisionID, hostID: hostID)
        let key = keys.sorted().first ?? AgentDecision.scopeKey(
            decisionID: decisionID,
            hostID: hostID?.uuidString
        )
        // Remove the visible notification and reschedule a fresh one after
        // the snooze interval. The decision itself stays open on cmux.
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: keys.map { "decision:\($0)" }
        )
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(minutes * 60),
            repeats: false
        )
        let content = UNMutableNotificationContent()
        content.title = L10n.string("notifications.snoozed_decision.title", defaultValue: "Snoozed agent decision")
        content.body = L10n.string(
            "notifications.snoozed_decision.body",
            defaultValue: "Still waiting for your decision. Tap to open."
        )
        content.categoryIdentifier = NotificationCategories.surfaceCategory
        content.interruptionLevel = .timeSensitive
        var userInfo: [AnyHashable: Any] = ["kind": "snoozed_decision", "decision_id": decisionID]
        if let hostID {
            userInfo["host_id"] = hostID.uuidString
        }
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: "decision:\(key):snoozed",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func clearAgentDecision(decisionID: String, hostID: UUID? = nil) async {
        let keys = decisionKeys(decisionID: decisionID, hostID: hostID)
        for key in keys {
            deliveredDecisions.remove(key)
            pendingDecisions.removeValue(forKey: key)
        }
        let center = UNUserNotificationCenter.current()
        let identifiers = await decisionNotificationIdentifiers(
            decisionID: decisionID,
            hostID: hostID,
            center: center
        )
        center.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
        center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
        await CMUXLiveActivityController.shared.endDecisionActivity(decisionID: decisionID, hostID: hostID)
    }

    func markAgentDecisionDeliveryFailed(decisionID: String, hostID: UUID? = nil) {
        for key in decisionKeys(decisionID: decisionID, hostID: hostID) {
            deliveredDecisions.remove(key)
        }
    }

    private static func isAlreadyResolvedDecisionError(_ error: any Error) -> Bool {
        guard case CmuxError.command(_, let stderr) = error else { return false }
        return stderr.contains("not_pending") || stderr.contains("not_found")
    }

    private static func decisionSignature(_ decision: AgentDecision) -> String {
        let choiceSignature = decision.choices.map { choice in
            let selections = choice.questionSelections?
                .map { selection in
                    "\(selection.questionID):\(selection.optionIDs.joined(separator: ","))"
                }
                .joined(separator: "|") ?? ""
            return "\(choice.id):\(choice.style.rawValue):\(choice.requiresAuth):\(selections)"
        }.joined(separator: ";")
        return [
            decision.itemID ?? "",
            decision.kind.rawValue,
            choiceSignature
        ].joined(separator: "#")
    }

    private func decisionNotificationIdentifiers(
        decisionID: String,
        hostID: UUID?,
        center: UNUserNotificationCenter
    ) async -> Set<String> {
        let prefixes = decisionKeys(decisionID: decisionID, hostID: hostID).map { "decision:\($0)" }
        var identifiers = Set(prefixes.flatMap { [$0, "\($0):snoozed", "\($0):unbound"] })
        // Compatibility cleanup for notifications delivered before host-scoped
        // decision identifiers existed.
        identifiers.insert("decision:\(decisionID)")
        identifiers.insert("decision:\(decisionID):snoozed")
        identifiers.insert("decision:\(decisionID):unbound")
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        for prefix in prefixes {
            identifiers.formUnion(delivered.filter { $0 == prefix || $0.hasPrefix("\(prefix):") })
            identifiers.formUnion(pending.filter { $0 == prefix || $0.hasPrefix("\(prefix):") })
        }
        return identifiers
    }

    private func isDecisionNotificationPresent(
        decisionID: String,
        hostID: UUID?,
        center: UNUserNotificationCenter
    ) async -> Bool {
        let prefixes = decisionKeys(decisionID: decisionID, hostID: hostID).map { "decision:\($0)" }
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        return (delivered + pending).contains { identifier in
            if identifier.hasSuffix(":unbound") { return false }
            return prefixes.contains { prefix in
                identifier == prefix || identifier.hasPrefix("\(prefix):")
            }
        }
    }

    private func unboundDecisionNotificationIdentifiers(
        decisionID: String,
        hostID: UUID?,
        center: UNUserNotificationCenter
    ) async -> Set<String> {
        let keys = decisionKeys(decisionID: decisionID, hostID: hostID)
        var identifiers = Set(keys.map { "decision:\($0):unbound" })
        identifiers.insert("decision:\(decisionID):unbound")
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        identifiers.formUnion((delivered + pending).filter { identifiers.contains($0) })
        return identifiers
    }

    private func decisionKeys(decisionID: String, hostID: UUID?) -> Set<String> {
        if let hostID {
            return [AgentDecision.scopeKey(decisionID: decisionID, hostID: hostID.uuidString)]
        }
        let suffix = ":\(decisionID)"
        var keys = Set(pendingDecisions.keys.filter { $0.hasSuffix(suffix) })
        keys.formUnion(deliveredDecisions.filter { $0.hasSuffix(suffix) })
        keys.insert(AgentDecision.scopeKey(decisionID: decisionID, hostID: nil))
        return keys
    }

    func applySnapshot(_ snapshot: ServerState.Snapshot) {
        let current = Set(snapshot.notifications.keys)
        let removed = lastSnapshotIDs.subtracting(current)
        lastSnapshotIDs = current

        // Remove server-side-dismissed notifications from iOS notification
        // center so the badge count stays accurate.
        if !removed.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: removed.map { $0.raw }
            )
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: removed.map { $0.raw }
            )
            for id in removed {
                delivered.remove(id)
                delivering.remove(id)
            }
        }

        // Surface new unread notifications. We rely on the cmux event stream
        // arriving while foregrounded — see BGScheduler for background
        // backfill.
        for notification in snapshot.notifications.values where !notification.isRead {
            if delivered.contains(notification.id) { continue }
            if delivering.contains(notification.id) { continue }
            delivering.insert(notification.id)
            Task { @MainActor in
                do {
                    try await schedule(notification, hostID: snapshot.hostID)
                    delivered.insert(notification.id)
                } catch {
                    log.warning("notification add failed", metadata: [
                        "notification_id": .string(notification.id.raw),
                        "error": .string(error.localizedDescription)
                    ])
                }
                delivering.remove(notification.id)
            }
        }

        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(snapshot.unreadNotifications)
        }
    }

    private func schedule(_ notification: CmuxNotification, hostID: UUID?) async throws {
        let content = UNMutableNotificationContent()
        content.title = CmuxNotificationPresentation.title(for: notification)
        content.subtitle = CmuxNotificationPresentation.subtitle(for: notification)
        content.body = CmuxNotificationPresentation.body(for: notification)
        content.categoryIdentifier = NotificationCategories.surfaceCategory
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 0.9
        if let workspaceID = notification.workspaceID {
            content.threadIdentifier = "workspace:\(workspaceID.raw)"
            content.userInfo["workspace_id"] = workspaceID.raw
        }
        if let surfaceID = notification.surfaceID {
            content.userInfo["surface_id"] = surfaceID.raw
        }
        if let hostID {
            content.userInfo["host_id"] = hostID.uuidString
        }
        content.userInfo["notification_id"] = notification.id.raw

        let request = UNNotificationRequest(
            identifier: notification.id.raw,
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo

        // Agent-decision branch: notifications carrying a "kind=agent_decision"
        // userInfo go through AgentDecisionNotifier, not the per-notification
        // mark-read/dismiss flow below.
        if let kind = info["kind"] as? String, kind == "agent_decision" {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                Task { @MainActor in
                    await openAgentDecisionContext(userInfo: info)
                    completionHandler()
                }
                return
            }
            Task {
                await AgentDecisionNotifier.handleAction(
                    actionID: response.actionIdentifier,
                    userInfo: info
                )
                completionHandler()
            }
            return
        }

        if let kind = info["kind"] as? String, kind == "stuck_surface" {
            Task { @MainActor in
                await handleStuckSurfaceAction(action: response.actionIdentifier, userInfo: info)
                completionHandler()
            }
            return
        }

        if let kind = info["kind"] as? String, kind == "snoozed_decision" {
            Task { @MainActor in
                await handleSnoozedDecisionAction(userInfo: info)
                completionHandler()
            }
            return
        }

        guard let raw = info["notification_id"] as? String else {
            completionHandler(); return
        }
        let id = NotificationID(raw)
        let action = response.actionIdentifier
        let hostID = Self.hostID(from: info)
        Task { @MainActor in
            switch action {
            case NotificationCategories.openAction,
                 UNNotificationDefaultActionIdentifier:
                await performRemoteNotificationAction("open-notification", hostID: hostID) { client in
                    try await client.openNotification(id)
                }
            case NotificationCategories.markReadAction:
                await performRemoteNotificationAction("mark-read", hostID: hostID) { client in
                    try await client.markRead(notificationID: id)
                }
            case NotificationCategories.dismissAction:
                await performRemoteNotificationAction("dismiss", hostID: hostID) { client in
                    try await client.dismiss(notificationID: id)
                }
            case NotificationCategories.replyAction:
                if let response = response as? UNTextInputNotificationResponse,
                   !response.userText.isEmpty,
                   let surfaceRaw = info["surface_id"] as? String {
                    await performRemoteNotificationAction("send", hostID: hostID) { client in
                        try await client.sendText(response.userText + "\n",
                                                  surfaceID: SurfaceID(surfaceRaw))
                    }
                }
            default:
                break
            }
            completionHandler()
        }
    }

    private func openAgentDecisionContext(userInfo: [AnyHashable: Any]) async {
        let workspaceID = (userInfo["workspace_id"] as? String).map { WorkspaceID($0) }
        let surfaceID = (userInfo["surface_id"] as? String).map { SurfaceID($0) }
        let hostID = Self.hostID(from: userInfo)
        guard workspaceID != nil || surfaceID != nil else { return }
        await performRemoteNotificationAction("open-agent-decision", hostID: hostID) { client in
            if let workspaceID {
                try await client.selectWorkspace(workspaceID)
            }
            if let surfaceID {
                try await client.focusSurface(surfaceID, workspaceID: workspaceID)
            }
        }
    }

    private func handleStuckSurfaceAction(
        action: String,
        userInfo: [AnyHashable: Any]
    ) async {
        guard let surfaceRaw = userInfo["surface_id"] as? String else { return }
        let surfaceID = SurfaceID(surfaceRaw)
        let workspaceID = (userInfo["workspace_id"] as? String).map { WorkspaceID($0) }
        let hostID = Self.hostID(from: userInfo)
        let identifierScope = hostID?.uuidString ?? "unbound"
        let identifier = "stuck:\(identifierScope):\(surfaceRaw)"
        let legacyIdentifier = "stuck:\(surfaceRaw)"
        let identifiers = [identifier, legacyIdentifier]
        let center = UNUserNotificationCenter.current()

        switch action {
        case NotificationCategories.openAction,
             UNNotificationDefaultActionIdentifier:
            await performRemoteNotificationAction("open-stuck-surface", hostID: hostID) { client in
                if let workspaceID {
                    try await client.selectWorkspace(workspaceID)
                }
                try await client.focusSurface(surfaceID, workspaceID: workspaceID)
            }
        case NotificationCategories.snoozeAction:
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            let minutes = max(1, AFKPolicyStore.shared.policy.snoozeMinutes)
            let content = UNMutableNotificationContent()
            content.title = L10n.string("notifications.stuck_after_snooze.title", defaultValue: "Agent still looks stuck")
            content.body = L10n.string(
                "notifications.stuck_after_snooze.body",
                defaultValue: "No new output after snoozing. Tap to open."
            )
            content.categoryIdentifier = NotificationCategories.stuckCategory
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = workspaceID.map { "workspace:\($0.raw)" } ?? "stuck"
            content.userInfo = userInfo
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(minutes * 60),
                repeats: false
            )
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            try? await center.add(request)
        case NotificationCategories.killAction:
            await performRemoteNotificationAction("ctrl-c-stuck-surface", hostID: hostID) { client in
                try await client.sendKey("ctrl-c", surfaceID: surfaceID, workspaceID: workspaceID)
            }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        default:
            break
        }
    }

    private func performRemoteNotificationAction(
        _ action: String,
        hostID: UUID? = nil,
        operation: (CMUXClient) async throws -> Void
    ) async {
        do {
            try await ConnectionManager.shared.performRemoteAction(
                action: action,
                hostID: hostID,
                operation: operation
            )
        } catch {
            log.warning("notification action failed", metadata: [
                "action": .string(action),
                "error": .string(error.localizedDescription)
            ])
            await postNotificationActionFailure(action: action)
        }
    }

    private static func hostID(from userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo["host_id"] as? String).flatMap(UUID.init(uuidString:))
    }

    private func postNotificationActionFailure(action: String) async {
        let content = UNMutableNotificationContent()
        content.title = L10n.string(
            "notifications.action_failed.title",
            defaultValue: "cmux action failed"
        )
        content.body = L10n.string(
            "notifications.action_failed.body",
            defaultValue: "Open cmux-remote and try again."
        )
        content.interruptionLevel = .passive
        content.threadIdentifier = "cmux-action-error"
        let request = UNNotificationRequest(
            identifier: "notification-action-error:\(action):\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func handleSnoozedDecisionAction(userInfo: [AnyHashable: Any]) async {
        guard let decisionID = userInfo["decision_id"] as? String else {
            await postDecisionNotice(
                id: "decision-error:\(UUID().uuidString)",
                title: L10n.string("decision.notification.error.title", defaultValue: "Decision not delivered"),
                body: L10n.string(
                    "decision.notification.error.malformed",
                    defaultValue: "Could not resolve the decision because the notification payload was invalid."
                )
            )
            return
        }
        let hostID = Self.hostID(from: userInfo)
        let key = AgentDecision.scopeKey(decisionID: decisionID, hostID: hostID?.uuidString)
        if let decision = pendingDecisions[key] ?? (hostID == nil ? pendingDecisions[decisionID] : nil) {
            guard decision.hasBoundFeedItem else {
                await postUnboundDecisionNotice(decision)
                return
            }
            deliveredDecisions.remove(decision.scopeKey)
            await AgentDecisionNotifier.reRegisterCategories(for: [decision])
            try? await UNUserNotificationCenter.current().add(AgentDecisionNotifier.makeRequest(for: decision))
            await CMUXLiveActivityController.shared.presentDecision(decision)
        } else {
            await postDecisionNotice(
                id: "decision-error:\(decisionID)",
                title: L10n.string("decision.notification.error.title", defaultValue: "Decision not delivered"),
                body: L10n.string(
                    "notifications.snoozed_decision.missing_body",
                    defaultValue: "cmux-remote no longer has this decision in memory. Open cmux on your Mac to resolve it."
                )
            )
        }
    }

    private func postDecisionNotice(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func postUnboundDecisionNotice(_ decision: AgentDecision) async {
        await postDecisionNotice(
            id: "decision:\(decision.scopeKey):unbound",
            title: L10n.string("decision.notification.error.title", defaultValue: "Decision not delivered"),
            body: L10n.string(
                "decision.notification.error.unbound_item",
                defaultValue: "cmux-remote could not verify the exact feed item for this decision. Open the app or cmux on your Mac to resolve it."
            )
        )
    }

    func postDecisionDeliveryFailure(decisionID: String, reason: String) async {
        await postDecisionNotice(
            id: "decision-delivery-error:\(decisionID):\(UUID().uuidString)",
            title: L10n.string("decision.notification.error.title", defaultValue: "Decision not delivered"),
            body: L10n.string(
                "decision.notification.error.background_delivery_failed",
                defaultValue: "cmux-remote could not deliver a decision in the background. Open the app to retry."
            )
        )
    }

    func postDecisionResolutionUnsupported(decisionID: String) async {
        await postDecisionNotice(
            id: "decision-unsupported:\(decisionID):\(UUID().uuidString)",
            title: L10n.string("decision.notification.error.title", defaultValue: "Decision not delivered"),
            body: L10n.string(
                "decision.notification.error.unsupported_remote",
                defaultValue: "This Mac needs a newer cmux before remote decisions can be resolved from cmux-remote."
            )
        )
    }
}

enum CmuxNotificationPresentation {
    static func title(for notification: CmuxNotification) -> String {
        L10n.string("notifications.generic.title", defaultValue: "cmux notification")
    }

    static func subtitle(for notification: CmuxNotification) -> String {
        ""
    }

    static func body(for notification: CmuxNotification) -> String {
        L10n.string(
            "notifications.generic.body",
            defaultValue: "An agent needs attention. Open cmux-remote to view details."
        )
    }
}

// Lightweight alias used in `schedule(_:workspaces:)` so the function
// signature stays readable.
typealias OrderedNotificationWorkspaceMap = OrderedDictionary<WorkspaceID, CmuxWorkspace>
