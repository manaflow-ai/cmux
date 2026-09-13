import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// These socket/command-path cases join the existing serialized title suite.
@MainActor
extension SetAutoTitleSocketTests {
    func withCloudNameFixture(_ body: (CloudNameAuthorityFixture) async throws -> Void) async throws {
        let fixture = try CloudNameAuthorityFixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test("Cmd+R terminal and workspace writes keep identity before and after an agent name", arguments: [false, true])
    func cloudUserRenameOrder(agentFirst: Bool) async throws {
        try await withCloudNameFixture { fixture in
            let oldContext = try #require(fixture.catalog.cloudAgentNameContext(
                workspaceID: fixture.workspace.id, panelID: fixture.panelID))
            if agentFirst { try await fixture.agentName("Calculate 2+2") }
            // These are the shared owner actions invoked by the command palette's
            // captured workspace UUID + panel UUID, including Cmd+R and Cmd+Shift+R.
            #expect(fixture.workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "API – 東京 🚀 / terminal:1"))
            #expect(fixture.manager.setCustomTitle(tabId: fixture.workspace.id, title: "machine: 任意 / workspace"))
            try await fixture.settle()
            try fixture.expectParity("API – 東京 🚀 / terminal:1", workspaceName: "machine: 任意 / workspace")
            try await fixture.agentName("Delayed agent", context: oldContext)
            _ = fixture.workspace.updatePanelTitle(panelId: fixture.panelID, title: "Old process")
            await fixture.provider.refresh()
            try fixture.expectParity("API – 東京 🚀 / terminal:1", workspaceName: "machine: 任意 / workspace")
            #expect(fixture.provider.graph.lookupIndex.tab(id: "tab_b")?.name == nil)
            #expect(fixture.provider.graph.lookupIndex.workspace(id: "b")?.name == "Same workspace")
        }
    }

    @Test("An older automatic result and old snapshots cannot replace an accepted name")
    func cloudLateCallbacks() async throws {
        try await withCloudNameFixture { fixture in
            let oldGraph = fixture.provider.graph
            let context = try #require(fixture.catalog.cloudAgentNameContext(workspaceID: fixture.workspace.id, panelID: fixture.panelID))
            try await fixture.agentName("New conversation", context: context)
            try await fixture.agentName("Old conversation", context: context)
            #expect(!fixture.provider.install(oldGraph))
            fixture.renameService.reconcileRemoteState(machine: fixture.provider.machine, state: oldGraph,
                                                       catalog: fixture.catalog, observation: .current)
            try fixture.expectParity("New conversation")
            // Another fresh automatic result can replace the preceding one.
            try await fixture.agentName("Latest conversation")
            try fixture.expectParity("Latest conversation")
        }
    }

    @Test("Arbitrary names survive native restore, daemon reconnect and notification refresh")
    func cloudNamesPersist() async throws {
        try await withCloudNameFixture { fixture in
            let workspace = fixture.workspace
            #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Logs & tests / 本番"))
            #expect(fixture.manager.setCustomTitle(tabId: workspace.id, title: "machine: API & tests 🚀"))
            try await fixture.settle()
            let saved = try JSONDecoder().decode(SessionWorkspaceSnapshot.self,
                from: JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false)))
            let restored = Workspace()
            let map = restored.restoreSessionSnapshot(saved)
            let panel = try #require(map[fixture.panelID])
            fixture.manager.tabs = [restored]
            defer { for value in restored.panels.values { value.close() } }
            fixture.catalog.endProjections(panelID: fixture.panelID, reason: .replaced)
            fixture.catalog.record(SurfaceProjection(resource: .init(machine: fixture.provider.machine, kind: .terminal, key: "term_a"),
                workspaceID: restored.id, panelID: panel, remoteWorkspaceID: "a", remoteTabID: "tab_a"))
            var snapshot = try #require(fixture.provider.graph.snapshotObject())
            snapshot["cursor"] = ["generation": "reconnected", "revision": "1"]
            snapshot["notifications"] = [["id": "notice", "terminal_id": "term_a", "title": "Old process"]]
            let reconnect = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: fixture.provider.machine))
            #expect(fixture.provider.install(reconnect))
            await fixture.provider.refresh()
            #expect(restored.title == "machine: API & tests 🚀")
            #expect(restored.panelTitle(panelId: panel) == "Logs & tests / 本番")
            let native = try #require(restored.surfaceIdFromPanelId(panel))
            #expect(restored.bonsplitController.tab(native)?.title == "Logs & tests / 本番")
            #expect(fixture.catalog.resources[.init(machine: fixture.provider.machine, kind: .terminal, key: "term_a")]?.remoteViews?.first?.name == "Logs & tests / 本番")
            fixture.catalog.endProjections(panelID: panel, reason: .replaced)
        }
    }

    @Test("A callback cannot cross machine or workspace identity despite identical display names")
    func cloudNameIdentity() async throws {
        try await withCloudNameFixture { fixture in
            let context = try #require(fixture.catalog.cloudAgentNameContext(workspaceID: fixture.workspace.id, panelID: fixture.panelID))
            let other = try CloudNameAuthorityTestProvider(machine: .cloud("other-" + UUID().uuidString),
                catalog: fixture.catalog, renameService: fixture.renameService)
            fixture.catalog.register(other)
            #expect(other.install(other.graph))
            defer { fixture.catalog.unregister(machine: other.machine) }
            #expect(fixture.catalog.cloudAgentNameContext(workspaceID: UUID(), panelID: fixture.panelID) == nil)
            var forged = try #require(context.wire)
            var projection = try #require(forged["projection"] as? [String: Any])
            projection["remoteWorkspaceID"] = "b"
            forged["projection"] = projection
            let result = try await fixture.call("surface.sync_codex_native_title", extra: [
                "title": "wrong workspace", "cloud_name_context": forged
            ])
            #expect(result["applied"] as? Bool == false)
            try await fixture.agentName("Correct terminal", context: context)
            try fixture.expectParity("Correct terminal")
            #expect(other.graph.lookupIndex.tab(id: "tab_a")?.name == nil)
            await other.receiver.stop()
        }
    }

    @Test("Clear restores process titles and a failed write leaves both views unchanged")
    func cloudClearAndRefusal() async throws {
        try await withCloudNameFixture { fixture in
            #expect(fixture.workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "User name"))
            try await fixture.settle()
            #expect(fixture.workspace.setPanelCustomTitle(panelId: fixture.panelID, title: nil))
            try await fixture.settle()
            try fixture.expectParity("terminal")
            try await fixture.agentName("Agent after clear")
            try fixture.expectParity("Agent after clear")
            fixture.provider.beforeRename = { throw CancellationError() }
            #expect(fixture.workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Refused name"))
            await #expect(throws: CancellationError.self) { try await fixture.settle() }
            try fixture.expectParity("Agent after clear")
        }
    }
    @Test("An unacknowledged user rename keeps layout/sidebar parity and rejects a racing auto result")
    func cloudPendingNameParity() async throws {
        try await withCloudNameFixture { fixture in
            let context = try #require(fixture.catalog.cloudAgentNameContext(workspaceID: fixture.workspace.id, panelID: fixture.panelID))
            let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            fixture.provider.beforeRename = {
                for await _ in gate.stream { break }
            }
            #expect(fixture.workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Chosen name"))
            try fixture.expectParity("terminal")
            let response = try await fixture.call("surface.sync_codex_native_title", extra: [
                "title": "Racing agent", "cloud_name_context": try #require(context.wire)
            ])
            #expect(response["applied"] as? Bool == false)
            try fixture.expectParity("terminal")
            gate.continuation.yield(())
            gate.continuation.finish()
            try await fixture.settle()
            try fixture.expectParity("Chosen name")
        }
    }

    @Test("Unnamed Cloud tabs continue to consume accepted process titles")
    func cloudUnnamedProcessTitles() async throws {
        try await withCloudNameFixture { fixture in
            var document = try #require(fixture.provider.graph.snapshotObject())
            var terminals = try #require(document["terminals"] as? [[String: Any]])
            terminals[0]["title"] = "vim README.md"
            document["terminals"] = terminals
            #expect(fixture.provider.install(try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: fixture.provider.machine))))
            try fixture.expectParity("vim README.md")
            _ = fixture.workspace.updatePanelTitle(panelId: fixture.panelID, title: "Delayed local OSC")
            try fixture.expectParity("vim README.md")
        }
    }

    @Test("A user confirming the same agent text claims the name")
    func cloudSameTextClaimsUserOwnership() async throws {
        try await withCloudNameFixture { fixture in
            try await fixture.agentName("Keep this name")
            #expect(fixture.workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Keep this name"))
            try await fixture.settle()
            #expect(fixture.provider.graph.lookupIndex.tab(id: "tab_a")?.nameAuthority?.source == .user)
            #expect(fixture.catalog.cloudAgentNameContext(workspaceID: fixture.workspace.id, panelID: fixture.panelID) == nil)
            try fixture.expectParity("Keep this name")
        }
    }

    @Test("A legacy Cloud projection resolves its workspace identity before renaming")
    func cloudLegacyWorkspaceNameAdmission() async throws {
        try await withCloudNameFixture { fixture in
            fixture.workspace.cloudVMBinding = nil
            #expect(fixture.manager.setCustomTitle(tabId: fixture.workspace.id, title: "machine: User's exact name"))
            #expect(fixture.workspace.cloudVMBinding?.remoteWorkspaceID == "a")
            try fixture.expectParity("terminal", workspaceName: "Same workspace")
            try await fixture.settle()
            try fixture.expectParity("terminal", workspaceName: "machine: User's exact name")
        }
    }

    @Test("Reporting a failed rename without a live window never starts a modal loop")
    func cloudRenameFailureWithoutWindowReturns() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        defer { for panel in workspace.panels.values { panel.close() } }
        #expect(manager.window == nil)
        workspace.presentCloudRenameFailure(SurfaceCatalogError.noProvider(.cloud("missing")))
        #expect(manager.window == nil)
    }

    @Test("A blank Cloud workspace name leaves its name and legacy binding untouched")
    func cloudBlankWorkspaceNameIsNotLocalAlias() async throws {
        try await withCloudNameFixture { fixture in
            fixture.workspace.cloudVMBinding = nil
            #expect(!fixture.manager.setCustomTitle(tabId: fixture.workspace.id, title: nil))
            #expect(fixture.workspace.cloudVMBinding == nil)
            #expect(fixture.provider.writes.isEmpty)
            try fixture.expectParity("terminal", workspaceName: "Same workspace")
        }
    }

}
