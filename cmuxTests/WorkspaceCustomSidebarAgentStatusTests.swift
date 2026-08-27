import CmuxFoundation
import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for `Workspace.customSidebarWorkspaceSnapshot` carrying the shared
/// `AgentStatus` down to each surface, so a custom sidebar and the pane border read the
/// same per-panel signal.
@Suite(.serialized)
struct WorkspaceCustomSidebarAgentStatusTests {
    @MainActor
    @Test("Surfaces carry the resolved agent status from the panel lifecycle map")
    func surfacesCarryResolvedAgentStatus() throws {
        let workspace = Workspace()

        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let tab = try #require(workspace.bonsplitController.tabs(inPane: paneId).first)
        let panelId = try #require(workspace.panelIdFromSurfaceId(tab.id))

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        let snapshot = workspace.customSidebarWorkspaceSnapshot(index: 0, selectedId: workspace.id, unreadCount: 0)
        let surface = try #require(snapshot.surfaces.first { $0.panelId == panelId })
        #expect(surface.agentStatus == .running)
    }

    @MainActor
    @Test("Error wins the reduction across sibling status keys")
    func errorWinsAcrossSiblingKeys() throws {
        let workspace = Workspace()

        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let tab = try #require(workspace.bonsplitController.tabs(inPane: paneId).first)
        let panelId = try #require(workspace.panelIdFromSurfaceId(tab.id))

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .error)
        workspace.setAgentLifecycle(key: "cmux.feed.attention:codex", panelId: panelId, lifecycle: .needsInput)

        let snapshot = workspace.customSidebarWorkspaceSnapshot(index: 0, selectedId: workspace.id, unreadCount: 0)
        let surface = try #require(snapshot.surfaces.first { $0.panelId == panelId })
        #expect(surface.agentStatus == .error)
    }

    @MainActor
    @Test("Manual loader keys are filtered and a panel with no lifecycle is none")
    func manualKeysFilteredAndNoneDefault() throws {
        let workspace = Workspace()

        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let tab = try #require(workspace.bonsplitController.tabs(inPane: paneId).first)
        let panelId = try #require(workspace.panelIdFromSurfaceId(tab.id))

        workspace.setAgentLifecycle(key: "manual:loader", panelId: panelId, lifecycle: .running)

        let snapshot = workspace.customSidebarWorkspaceSnapshot(index: 0, selectedId: workspace.id, unreadCount: 0)
        let surface = try #require(snapshot.surfaces.first { $0.panelId == panelId })
        #expect(surface.agentStatus == .none)
    }

    /// A pane reused by a second agent still carries the first agent's
    /// restored error (startup replay keeps `error` and drops `running`).
    /// Reporting the new occupant has to drop that leftover, or the border
    /// stays red after the turn ends too — idle does not outrank error.
    @MainActor
    @Test("A live agent reporting clears a previous agent's leftover error")
    func aLiveAgentReportingClearsAPreviousAgentsLeftoverError() throws {
        let workspace = Workspace()

        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let tab = try #require(workspace.bonsplitController.tabs(inPane: paneId).first)
        let panelId = try #require(workspace.panelIdFromSurfaceId(tab.id))

        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .error)
        workspace.setAgentLifecycle(key: "cursor", panelId: panelId, lifecycle: .running)

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["claude_code"] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["cursor"] == .running)

        let snapshot = workspace.customSidebarWorkspaceSnapshot(index: 0, selectedId: workspace.id, unreadCount: 0)
        let surface = try #require(snapshot.surfaces.first { $0.panelId == panelId })
        #expect(surface.agentStatus == .running)

        workspace.setAgentLifecycle(key: "cursor", panelId: panelId, lifecycle: .idle)
        let idleSnapshot = workspace.customSidebarWorkspaceSnapshot(index: 0, selectedId: workspace.id, unreadCount: 0)
        let idleSurface = try #require(idleSnapshot.surfaces.first { $0.panelId == panelId })
        #expect(idleSurface.agentStatus == .idle)
    }
}
