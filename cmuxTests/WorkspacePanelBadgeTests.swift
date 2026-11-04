import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspacePanelBadgeTests {
    private func tabTitle(_ workspace: Workspace, _ panelId: UUID) -> String? {
        workspace.surfaceIdFromPanelId(panelId).flatMap { workspace.bonsplitController.tab($0)?.title }
    }

    private func badge(_ text: String) throws -> PanelBadgeText {
        try #require(PanelBadgeText(text))
    }

    @Test
    func badgePrefixesLiveTitleAndFollowsTitleUpdates() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.updatePanelTitle(panelId: panelId, title: "first title"))

        #expect(workspace.setPanelBadge(panelId: panelId, badge: try badge("🦀")))
        #expect(workspace.panelBadges[panelId]?.value == "🦀")
        #expect(tabTitle(workspace, panelId) == "🦀 first title")
        #expect(workspace.panelTitle(panelId: panelId) == "🦀 first title")
        #expect(workspace.panelTitle(panelId: panelId, includesBadge: false) == "first title")

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "second title"))
        #expect(tabTitle(workspace, panelId) == "🦀 second title")
    }

    @Test
    func badgePrefixesCustomTitleWithoutReplacingIt() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setPanelBadge(panelId: panelId, badge: try badge("💼"))

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "build logs"))
        #expect(tabTitle(workspace, panelId) == "💼 build logs")
        #expect(workspace.panelCustomTitles[panelId] == "build logs")
    }

    @Test
    func clearingBadgeRestoresPlainTitle() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.updatePanelTitle(panelId: panelId, title: "live title"))
        workspace.setPanelBadge(panelId: panelId, badge: try badge("🦀"))

        #expect(workspace.setPanelBadge(panelId: panelId, badge: nil))
        #expect(workspace.panelBadges[panelId] == nil)
        #expect(tabTitle(workspace, panelId) == "live title")
    }

    @Test
    func badgingFocusedPanelRefreshesWorkspaceTitleObservers() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "session"))

        var notifiedWorkspaceIds: [UUID] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .workspaceTitleDidChange,
            object: manager,
            queue: nil
        ) { notification in
            if let workspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID {
                notifiedWorkspaceIds.append(workspaceId)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        workspace.setPanelBadge(panelId: panelId, badge: try badge("🦀"))
        #expect(workspace.title == "🦀 session")
        #expect(notifiedWorkspaceIds == [workspace.id])
    }

    @Test
    func setBadgeRejectsUnknownPanelWithoutWritingState() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(!workspace.setPanelBadge(panelId: UUID(), badge: try badge("🦀")))
        #expect(workspace.panelBadges.isEmpty)
    }

    @Test
    func tearingDownPanelsDropsTheirBadges() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let initialPanelId = try #require(workspace.focusedPanelId)
        let splitPanel = try #require(
            workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal)
        )
        workspace.setPanelBadge(panelId: initialPanelId, badge: try badge("🦀"))
        workspace.setPanelBadge(panelId: splitPanel.id, badge: try badge("💼"))
        #expect(workspace.panelBadges.count == 2)

        workspace.teardownAllPanels()

        #expect(workspace.panels.isEmpty)
        #expect(workspace.panelBadges.isEmpty)
    }

    @Test
    func movingTabBetweenWorkspacesKeepsBadgeOutOfStoredTitle() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let source = try #require(manager.selectedWorkspace)
        let destination = manager.addWorkspace(select: false)
        let anchorId = try #require(source.focusedPanelId)
        let moved = try #require(source.newTerminalSplit(from: anchorId, orientation: .horizontal))
        #expect(source.updatePanelTitle(panelId: moved.id, title: "live title"))
        source.setPanelBadge(panelId: moved.id, badge: try badge("🦀"))

        let detached = try #require(source.detachSurface(panelId: moved.id))
        #expect(detached.badge?.value == "🦀")
        #expect(detached.title == "live title")
        #expect(source.panelBadges[moved.id] == nil)

        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        _ = try #require(destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false))
        #expect(destination.panelBadges[moved.id]?.value == "🦀")
        #expect(tabTitle(destination, moved.id) == "🦀 live title")
    }

    @Test
    func respawningTerminalKeepsBadge() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setPanelBadge(panelId: panelId, badge: try badge("🦀"))

        _ = try #require(workspace.respawnTerminalSurface(panelId: panelId, command: "echo replacement"))

        #expect(workspace.panelBadges[panelId]?.value == "🦀")
        #expect(tabTitle(workspace, panelId)?.hasPrefix("🦀 ") == true)
    }

    @Test
    func sessionSnapshotStoresBadgeSeparatelyAndRestoresItOnce() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.updatePanelTitle(panelId: panelId, title: "live title"))
        workspace.setPanelBadge(panelId: panelId, badge: try badge("🦀"))

        let panelSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelId }
        )
        #expect(panelSnapshot.badge == "🦀")
        #expect(panelSnapshot.title == "live title")

        // Round-trip through JSON, as the session file does.
        let encoded = try JSONEncoder().encode(manager.sessionSnapshot(includeScrollback: false))
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: encoded)

        let restored = TabManager(autoWelcomeIfNeeded: false)
        restored.restoreSessionSnapshot(decoded)
        let restoredWorkspace = try #require(restored.selectedWorkspace)
        let restoredPanelId = try #require(restoredWorkspace.panelBadges.first?.key)
        #expect(restoredWorkspace.panelBadges[restoredPanelId]?.value == "🦀")
        #expect(tabTitle(restoredWorkspace, restoredPanelId) == "🦀 live title")
    }

    @Test
    func restoreDropsBadgeTheSocketWouldReject() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        var panelSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelId }
        )
        panelSnapshot.badge = "bad\nbadge"

        workspace.applySessionPanelMetadata(panelSnapshot, toPanelId: panelId)

        #expect(workspace.panelBadges[panelId] == nil)
    }

    @Test
    func panelSnapshotWithoutBadgeKeyDecodes() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setPanelBadge(panelId: panelId, badge: try badge("🦀"))
        let panelSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelId }
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(panelSnapshot)) as? [String: Any]
        )
        #expect(object["badge"] as? String == "🦀")
        object.removeValue(forKey: "badge")

        let decoded = try JSONDecoder().decode(
            SessionPanelSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.badge == nil)
    }
}
