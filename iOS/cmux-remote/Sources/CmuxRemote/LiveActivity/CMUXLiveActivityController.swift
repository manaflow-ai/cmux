import Foundation
@preconcurrency import ActivityKit
import CmuxKit
import Combine
import Logging
import WidgetKit

@MainActor
final class CMUXLiveActivityController: ObservableObject {
    static let shared = CMUXLiveActivityController()

    private let log = CmuxLog.make("liveactivity")
    private var activity: Activity<CMUXActivityAttributes>?
    private var lastState: CMUXActivityAttributes.ContentState?
    private enum SnapshotActivityUpdate {
        case end
        case update(state: CMUXActivityAttributes.ContentState, host: CmuxHost)
    }
    private var pendingSnapshotUpdate: SnapshotActivityUpdate?
    private var snapshotUpdateTask: Task<Void, Never>?
    private struct WidgetEntrySignature: Equatable {
        let workspaceTitle: String
        let branch: String?
        let unread: Int
        let host: String
    }
    private var lastWidgetSignature: WidgetEntrySignature?
    private var widgetReloadTask: Task<Void, Never>?

    func applySnapshot(_ snapshot: ServerState.Snapshot) {
        guard let hostID = snapshot.hostID,
              let host = HostStore.shared.hosts.first(where: { $0.id == hostID }) else {
            pendingSnapshotUpdate = .end
            startSnapshotUpdateLoop()
            return
        }

        // Keep Home Screen / Lock Screen widgets current even when the
        // user disables Live Activities. Widget text remains generic so
        // server notification content is never cached into the App Group.
        let widgetEntry = CmuxWidgetEntry(
            date: Date(),
            workspaceTitle: L10n.string("live_activity.workspace.generic", defaultValue: "cmux workspace"),
            branch: nil,
            unread: snapshot.unreadNotifications,
            host: L10n.string("widget.host.generic", defaultValue: "cmux")
        )
        scheduleWidgetUpdate(widgetEntry)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            pendingSnapshotUpdate = .end
            startSnapshotUpdateLoop()
            return
        }

        let mostRecentNotification = snapshot.notifications.values
            .sorted(by: { $0.createdAt > $1.createdAt })
            .first

        let state = CMUXActivityAttributes.ContentState(
            workspaceTitle: L10n.string("live_activity.workspace.generic", defaultValue: "cmux workspace"),
            workspaceBranch: nil,
            pendingCount: snapshot.unreadNotifications,
            lastSurfaceTitle: nil,
            lastNotificationBody: mostRecentNotification == nil
                ? nil
                : L10n.string("notifications.live_activity.generic_body", defaultValue: "An agent needs attention."),
            phaseLabel: phaseLabel(for: snapshot.connectionPhase),
            isLive: phaseIsLive(snapshot.connectionPhase)
        )

        pendingSnapshotUpdate = .update(state: state, host: host)
        startSnapshotUpdateLoop()
    }

    private func scheduleWidgetUpdate(_ entry: CmuxWidgetEntry) {
        let signature = WidgetEntrySignature(
            workspaceTitle: entry.workspaceTitle,
            branch: entry.branch,
            unread: entry.unread,
            host: entry.host
        )
        guard signature != lastWidgetSignature else { return }
        lastWidgetSignature = signature
        Task.detached(priority: .utility) {
            CmuxWidgetStateStore.shared.write(entry)
        }
        guard widgetReloadTask == nil else { return }
        widgetReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            WidgetCenter.shared.reloadAllTimelines()
            await MainActor.run {
                self?.widgetReloadTask = nil
            }
        }
    }

    private func startSnapshotUpdateLoop() {
        guard snapshotUpdateTask == nil else { return }
        snapshotUpdateTask = Task { [weak self] in
            await self?.drainSnapshotUpdates()
        }
    }

    private func drainSnapshotUpdates() async {
        while true {
            guard let queuedUpdate = pendingSnapshotUpdate else {
                snapshotUpdateTask = nil
                return
            }
            pendingSnapshotUpdate = nil
            switch queuedUpdate {
            case .end:
                await endIfActive()
            case .update(let state, let host):
                await update(state: state, host: host)
            }
        }
    }

    private func update(state: CMUXActivityAttributes.ContentState, host: CmuxHost) async {
        await restoreHostActivity(for: host.id)
        if state == lastState, activity != nil { return }
        lastState = state
        let attributes = CMUXActivityAttributes(
            hostLabel: L10n.string("widget.host.generic", defaultValue: "cmux"),
            hostID: host.id
        )
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(120),
            relevanceScore: state.pendingCount > 0 ? 1.0 : 0.5
        )
        if let activity {
            await activity.update(content)
        } else {
            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                self.activity = activity
            } catch {
                log.warning("could not start Live Activity: \(error.localizedDescription)")
            }
        }
    }

    func endIfActive() async {
        let activities = Activity<CMUXActivityAttributes>.activities
        if activities.isEmpty, let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
        } else {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        activity = nil
        lastState = nil
    }

    private func restoreHostActivity(for hostID: UUID) async {
        let activities = Activity<CMUXActivityAttributes>.activities
        for stale in activities where stale.attributes.hostID != hostID {
            await stale.end(nil, dismissalPolicy: .immediate)
        }
        let matching = activities.filter { $0.attributes.hostID == hostID }
        guard let first = matching.first else {
            activity = nil
            return
        }
        activity = first
        for duplicate in matching.dropFirst() {
            await duplicate.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: - Agent decision activities

    private var decisionActivities: [String: Activity<AgentDecisionActivityAttributes>] = [:]

    func presentDecision(_ decision: AgentDecision) async {
        guard decision.hasBoundFeedItem else {
            log.warning("decision live activity suppressed because item_id is missing", metadata: [
                "decision_id": .string(decision.id),
                "kind": .string(decision.kind.rawValue)
            ])
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await restoreDecisionActivities()
        if decisionActivities[decision.scopeKey] != nil { return }
        let attributes = AgentDecisionActivityAttributes(
            decisionID: decision.id,
            itemID: decision.itemID,
            decisionKind: decision.kind.rawValue,
            agentName: L10n.string("decision.agent.generic", defaultValue: "cmux agent"),
            hostID: decision.hostID?.uuidString,
            workspaceID: decision.workspaceID?.raw,
            surfaceID: decision.surfaceID?.raw
        )
        let state = AgentDecisionActivityAttributes.ContentState(
            summary: L10n.string(
                "decision.live_activity.summary",
                defaultValue: "Agent is waiting for approval"
            ),
            // Same privacy invariant as AgentDecisionNotifier: the Live
            // Activity is visible on the Lock Screen / Dynamic Island
            // before the user unlocks the device, so raw command/diff
            // detail and server-provided choice labels are omitted by
            // policy.
            detail: nil,
            choices: decision.choices.enumerated().map { idx, choice in
                let optionIDs = ["A", "B", "C", "D", "E", "F", "G", "H"]
                let key = idx < optionIDs.count ? optionIDs[idx] : String(idx + 1)
                return AgentDecisionActivityAttributes.Choice(
                    id: choice.id,
                    label: L10n.format("decision.notification.option", defaultValue: "Option %@", key),
                    replyLabel: nil,
                    requiresAuth: choice.requiresAuth,
                    isDestructive: choice.style == .destructive,
                    isAffirmative: choice.style == .affirmative,
                    questionSelections: choice.questionSelections
                )
            },
            resolved: false,
            resolvedChoice: nil
        )
        let content = ActivityContent(
            state: state,
            staleDate: decision.expiresAt ?? Date().addingTimeInterval(300),
            relevanceScore: 1.0
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            decisionActivities[decision.scopeKey] = activity
        } catch {
            log.warning("decision live activity start failed: \(error.localizedDescription)")
        }
    }

    func endDecisionActivity(decisionID: String, hostID: UUID? = nil) async {
        await restoreDecisionActivities()
        let targetKey = hostID.map {
            AgentDecision.scopeKey(decisionID: decisionID, hostID: $0.uuidString)
        }
        let matching = Activity<AgentDecisionActivityAttributes>.activities
            .filter { activity in
                guard activity.attributes.decisionID == decisionID else { return false }
                guard let hostID else { return true }
                return activity.attributes.hostID == hostID.uuidString
            }
        let fallback = targetKey.flatMap { decisionActivities.removeValue(forKey: $0) }
        let activities = matching.isEmpty ? fallback.map { [$0] } ?? [] : matching
        guard !activities.isEmpty else { return }
        for activity in activities {
            let finalState = AgentDecisionActivityAttributes.ContentState(
                summary: L10n.string("agent_decision.resolved", defaultValue: "Resolved"),
                detail: nil,
                choices: activity.content.state.choices,
                resolved: true,
                resolvedChoice: nil
            )
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(8))
            )
        }
        if let targetKey {
            decisionActivities.removeValue(forKey: targetKey)
        } else {
            decisionActivities = decisionActivities.filter { _, activity in
                activity.attributes.decisionID != decisionID
            }
        }
    }

    private func restoreDecisionActivities() async {
        var restored: [String: Activity<AgentDecisionActivityAttributes>] = [:]
        for activity in Activity<AgentDecisionActivityAttributes>.activities {
            let key = AgentDecision.scopeKey(
                decisionID: activity.attributes.decisionID,
                hostID: activity.attributes.hostID
            )
            if restored[key] == nil {
                restored[key] = activity
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        decisionActivities = restored
    }

    private func phaseLabel(for phase: ServerState.ConnectionPhase) -> String {
        switch phase {
        case .live: return L10n.string("connection.phase.live", defaultValue: "Live")
        case .syncing: return L10n.string("connection.phase.syncing", defaultValue: "Syncing")
        case .connecting: return L10n.string("connection.phase.connecting", defaultValue: "Connecting")
        case .authenticating: return L10n.string("connection.phase.auth.short", defaultValue: "Auth")
        case .disconnected: return L10n.string("connection.phase.offline", defaultValue: "Offline")
        }
    }

    private func phaseIsLive(_ phase: ServerState.ConnectionPhase) -> Bool {
        if case .live = phase { return true }
        return false
    }
}
