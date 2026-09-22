import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud rename ordering and persistence")
struct CloudSidebarRenameReconciliationTests {
    private struct Rejected: Error {}

    @Test("An RPC receipt protects agent names until an accepted graph catches up")
    func receiptProtectsAgentName() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        #expect(fixture.manager.syncAgentTerminalTitle(tabId: workspace.id, panelId: fixture.panelID,
            title: "Calculate 2+2", catalog: fixture.catalog))
        try await fixture.drain()
        let receipt = CloudVMPendingMutation(kind: .tabRename, remoteTabID: "tab_main",
            name: "Calculate 2+2", receipt: .init(generation: "fixture", revision: 5))
        let stale = try fixture.state(revision: 2)
        fixture.install(stale, observation: .init(freshness: .current, reason: nil, pendingWrites: [receipt]))
        fixture.reconcile()
        #expect(workspace.panelTitle(panelId: fixture.panelID) == "Calculate 2+2")
        #expect(workspace.panelCustomTitleSources[fixture.panelID] == .auto)
        fixture.install(try fixture.state(revision: 5, name: "Calculate 2+2"))
        fixture.reconcile()
        fixture.service.reconcileRemoteState(machine: fixture.machine, state: stale, catalog: fixture.catalog, observation: .current)
        try fixture.assertParity("Calculate 2+2")
        #expect(workspace.panelCustomTitleSources[fixture.panelID] == .auto)
    }

    @Test("The latest user name survives superseded failures and delayed graph callbacks")
    func supersededFailureCannotCompensateNewUserIntent() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        var attempt = 0
        fixture.provider.beforeMutation = {
            attempt += 1
            if attempt == 1 { throw Rejected() }
        }
        #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Same label", catalog: fixture.catalog))
        #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Same label", catalog: fixture.catalog))
        try await fixture.drain()
        #expect(workspace.panelCustomTitles[fixture.panelID] == "Same label")
        #expect(workspace.panelCustomTitleSources[fixture.panelID] == .user)
        #expect(fixture.provider.tabRenames == ["Same label"])
        let old = try fixture.state()
        fixture.install(try fixture.state(revision: 3, name: "Same label"))
        fixture.reconcile()
        fixture.service.reconcileRemoteState(machine: fixture.machine, state: old, catalog: fixture.catalog, observation: .current)
        try fixture.assertParity("Same label")
    }

    @Test("Failed agent rename restores the previous automatic title and ownership")
    func failedAgentRenameRollsBack() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Earlier task", source: .auto, catalog: fixture.catalog))
        try await fixture.drain()
        fixture.install(try fixture.state(revision: 2, name: "Earlier task"))
        fixture.reconcile()
        fixture.provider.beforeMutation = { throw Rejected() }
        #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Failed task", source: .auto, catalog: fixture.catalog))
        try await fixture.drain()
        #expect(workspace.panelCustomTitleSources[fixture.panelID] == .auto)
        try fixture.assertParity("Earlier task")
    }

    @Test("A rename rejected after a remote edit converges immediately to that accepted name")
    func failedRenameUsesNewerRemoteName() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.provider.beforeMutation = {
            fixture.install(try fixture.state(revision: 2, name: "Remote user label"))
            fixture.reconcile()
            throw Rejected()
        }
        #expect(fixture.manager.syncAgentTerminalTitle(tabId: fixture.workspace.id, panelId: fixture.panelID,
            title: "Calculate 2+2", catalog: fixture.catalog))
        try await fixture.drain()
        try fixture.assertParity("Remote user label")
        #expect(fixture.workspace.panelCustomTitleSources[fixture.panelID] == .remote)
    }

    @Test("A failed rename chain restores the accepted name, never an uncommitted intermediate name")
    func failedChainRestoresCanonicalName() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.provider.beforeMutation = { throw Rejected() }
        #expect(fixture.workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Failed first", catalog: fixture.catalog))
        #expect(fixture.workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Failed second", catalog: fixture.catalog))
        try await fixture.drain()
        #expect(fixture.workspace.panelCustomTitles[fixture.panelID] == nil)
        #expect(fixture.workspace.panelTitle(panelId: fixture.panelID) == "terminal")
    }

    @Test("Agent and user names survive persisted session restore and daemon reconnect", arguments: [false, true])
    func titlePersistence(userOwned: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let source: Workspace.CustomTitleSource = userOwned ? .user : .auto
        let title = "Build / 東京 🚀"
        #expect(fixture.workspace.setPanelCustomTitle(panelId: fixture.panelID, title: title, source: source, catalog: fixture.catalog))
        try await fixture.drain()
        fixture.install(try fixture.state(revision: 2, name: title))
        fixture.reconcile()
        let data = try JSONEncoder().encode(fixture.workspace.sessionSnapshot(includeScrollback: false))
        let snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        let restored = Workspace()
        let panels = restored.restoreSessionSnapshot(snapshot)
        let restoredPanel = try #require(panels[fixture.panelID])
        fixture.manager.tabs = [restored]
        defer { for panel in restored.panels.values { panel.close() } }
        let graph = try fixture.state(generation: "reconnected", name: title)
        // Cross the daemon serialization boundary too, not just a local display copy.
        let bytes = try JSONSerialization.data(withJSONObject: try #require(graph.snapshotObject()))
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        fixture.install(try #require(CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: fixture.machine)))
        fixture.catalog.record(SurfaceProjection(resource: fixture.resourceID, workspaceID: restored.id,
            panelID: restoredPanel, remoteWorkspaceID: "ws_main", remoteTabID: "tab_main"))
        fixture.reconcile()
        #expect(restored.panelTitle(panelId: restoredPanel) == title)
        #expect(restored.panelCustomTitleSources[restoredPanel] == source)
        #expect(restored.cloudVMBinding?.remoteWorkspaceID == "ws_main")
        #expect(fixture.catalog.cloudStates[fixture.machine]?.lookupIndex.tab(id: "tab_main")?.name == title)
    }

    @Test("A stale peer cannot auto-rename an explicitly named shared placement")
    func peerUserOwnershipBlocksAutoRename() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Human label", catalog: fixture.catalog))
        let peer = Workspace()
        fixture.manager.tabs.append(peer)
        defer { for panel in peer.panels.values { panel.close() } }
        let panel = try #require(peer.focusedPanelId)
        fixture.catalog.record(SurfaceProjection(resource: fixture.resourceID, workspaceID: peer.id,
            panelID: panel, remoteWorkspaceID: "ws_main", remoteTabID: "tab_main"))
        #expect(!peer.setPanelCustomTitle(panelId: panel, title: "Delayed agent", source: .auto, catalog: fixture.catalog))
        try await fixture.drain()
        fixture.install(try fixture.state(revision: 2, name: "Human label"))
        fixture.reconcile()
        #expect(peer.panelTitle(panelId: panel) == "Human label")
        #expect(fixture.provider.tabRenames == ["Human label"])
    }

    @Test("Mirroring an agent-named placement does not block its next agent title")
    func remotePeerConfirmationRetainsAgentOwnership() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "First task", source: .auto, catalog: fixture.catalog))
        try await fixture.drain()
        fixture.install(try fixture.state(revision: 2, name: "First task"))
        let peer = Workspace()
        fixture.manager.tabs.append(peer)
        defer { for panel in peer.panels.values { panel.close() } }
        let panel = try #require(peer.focusedPanelId)
        fixture.catalog.record(SurfaceProjection(resource: fixture.resourceID, workspaceID: peer.id,
            panelID: panel, remoteWorkspaceID: "ws_main", remoteTabID: "tab_main"))
        fixture.reconcile()
        #expect(peer.panelCustomTitleSources[panel] == .remote)
        #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Second task", source: .auto, catalog: fixture.catalog))
        try await fixture.drain()
        fixture.install(try fixture.state(revision: 3, name: "Second task"))
        fixture.reconcile()
        #expect(peer.panelTitle(panelId: panel) == "Second task")
        try fixture.assertParity("Second task")
    }

    private func makeFixture() throws -> CloudSidebarRenameFixture {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let service = CloudWorkspaceRenameService(environment: .init(
            workspace: { manager.workspacesById[$0] }, tabManager: { _ in manager }, workspaces: { manager.tabs }
        ))
        return try CloudSidebarRenameFixture(manager: manager, workspace: workspace,
            catalog: SurfaceCatalog(cloudWorkspaceRenameService: service))
    }
}
