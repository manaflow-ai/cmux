import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Builds before manaflow-ai/cmux#12667 recorded cmux's own memory-pressure
/// warning as a workspace-level notification on whichever workspace was
/// selected. Nothing posts or clears that record any more, so a persisted copy
/// stayed as one workspace's sidebar subtitle across every relaunch
/// (manaflow-ai/cmux#21847). Restore must drop it while keeping every other
/// workspace-level notification, including one a user sent with the same title.
@MainActor
@Suite(.serialized)
struct RetiredMemoryPressureNoticeRestoreTests {
    @Test func restoreDropsRetiredMemoryPressureNoticesAndKeepsOtherWorkspaceNotifications() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalNotificationStore = appDelegate.notificationStore
        appDelegate.notificationStore = store
        store.replaceNotificationsForTesting([])
        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let notices: [(title: String, subtitle: String, surfaceId: UUID?, isRead: Bool)] = [
            // The reporter's record: zh-Hans UI, already read, no surface.
            ("cmux 正处于严重内存压力下", "已释放隐藏的渲染器和浏览器", nil, true),
            ("cmux is under critical memory pressure", "Hidden renderers and browsers were released", nil, false),
            ("cmux is using substantial aggregate memory", "Idle agent surfaces may be hibernated", nil, true),
            // A user may still send the former title; only the exact retired pair is dropped.
            ("cmux is using substantial aggregate memory", "User message", nil, true),
            ("Machine ready", "Cloud", nil, true),
            // A pane notification with the retired text is not cmux's workspace-level notice.
            ("cmux is under critical memory pressure", "Hidden renderers and browsers were released", panelId, true),
        ]
        store.replaceNotificationsForTesting(notices.enumerated().map { index, notice in
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: notice.surfaceId,
                panelId: notice.surfaceId,
                title: notice.title,
                subtitle: notice.subtitle,
                body: "Body \(index)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                isRead: notice.isRead,
                isAgentEvent: false
            )
        })

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.notifications?.count == 5)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)

        let workspaceLevel = store.notifications(forTabId: restored.id, surfaceId: nil)
        #expect(Set(workspaceLevel.map(\.subtitle)) == ["User message", "Cloud"])
        #expect(store.notifications(forTabId: restored.id, surfaceId: restoredPanelId).count == 1)
        #expect(!store.workspaceIsUnread(forTabId: restored.id))
    }
}
