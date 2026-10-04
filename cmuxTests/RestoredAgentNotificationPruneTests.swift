import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An agent that was alive when cmux quit dies with the app without firing
/// SessionEnd, so its last notification used to be restored on every launch and
/// shown as the workspace's latest summary forever. The periodic stale-agent
/// sweep (`clearStaleAgentPIDs`) is what must notice it.
@MainActor
@Suite(.serialized)
struct RestoredAgentNotificationPruneTests {
    @Test func readNotificationOfAgentThatDidNotReturnIsPrunedAfterRestore() throws {
        try withIsolatedNotificationStore { store in
            let (restored, panelId) = try restoreWorkspace(store: store, hostsAgent: true, notifications: [
                (body: "Read turn summary", isRead: true),
                (body: "Unread turn summary", isRead: false),
            ])
            #expect(store.notifications(forTabId: restored.id, surfaceId: panelId).count == 2)

            restored.clearStaleAgentPIDs(refreshPorts: false)

            let remaining = store.notifications(forTabId: restored.id, surfaceId: panelId)
            #expect(remaining.map(\.body) == ["Unread turn summary"])
        }
    }

    @Test func readNotificationIsKeptWhenAgentReturnsToThePane() throws {
        try withIsolatedNotificationStore { store in
            let (restored, panelId) = try restoreWorkspace(store: store, hostsAgent: true, notifications: [
                (body: "Read turn summary", isRead: true),
            ])
            restored.recordAgentPID(key: "claude_code", pid: getpid(), panelId: panelId, refreshPorts: false)

            restored.clearStaleAgentPIDs(refreshPorts: false)

            #expect(store.notifications(forTabId: restored.id, surfaceId: panelId).map(\.body) == ["Read turn summary"])
        }
    }

    @Test func readNotificationOnPaneWithoutAgentIsLeftAlone() throws {
        try withIsolatedNotificationStore { store in
            let (restored, panelId) = try restoreWorkspace(store: store, hostsAgent: false, notifications: [
                (body: "Build finished", isRead: true),
            ])

            restored.clearStaleAgentPIDs(refreshPorts: false)

            #expect(store.notifications(forTabId: restored.id, surfaceId: panelId).map(\.body) == ["Build finished"])
        }
    }

    private func withIsolatedNotificationStore(_ body: (TerminalNotificationStore) throws -> Void) throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalNotificationStore = appDelegate.notificationStore
        appDelegate.notificationStore = store
        store.replaceNotificationsForTesting([])
        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }
        try body(store)
    }

    /// Persists a workspace whose focused pane holds `notifications`, then
    /// restores it into a fresh workspace with agent auto-resume disabled, the
    /// same state a relaunch leaves behind when the agent does not come back.
    private func restoreWorkspace(
        store: TerminalNotificationStore,
        hostsAgent: Bool,
        notifications: [(body: String, isRead: Bool)]
    ) throws -> (Workspace, UUID) {
        let suiteName = "cmux-restored-agent-notifications-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panelId = try #require(workspace.focusedPanelId)
        if hostsAgent {
            #expect(workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "Claude Code",
                    kind: "claude",
                    command: "claude --resume session-restored-agent-notification",
                    cwd: "/tmp",
                    checkpointId: "session-restored-agent-notification",
                    source: "agent-hook",
                    autoResume: false,
                    updatedAt: 10
                ),
                panelId: panelId
            ))
        }
        store.replaceNotificationsForTesting(notifications.enumerated().map { index, notification in
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: panelId,
                panelId: panelId,
                title: "Claude Code",
                subtitle: "Completed",
                body: notification.body,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                isRead: notification.isRead
            )
        })

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])
        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)
        return (restored, restoredPanelId)
    }
}
