import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// These run in the existing serialized socket suite, through the actual Codex hook.
extension SetAutoTitleSocketTests {
    @Test("Codex native title reaches its daemon placement; Cmd+R remains independently usable")
    func cloudNativeTitleAndWorkspaceRename() async throws {
        try await withManagerAsync { manager, workspace in
            let fixture = try CloudSidebarRenameFixture(manager: manager, workspace: workspace, catalog: .shared)
            defer { fixture.close() }
            let response = try await callAsync(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString,
                "panel_id": fixture.panelID.uuidString,
                "title": "Calculate 2+2"
            ])
            #expect(response["ok"] as? Bool == true)
            try await fixture.drain()
            #expect(fixture.provider.renamedTabs.map(\.id) == ["tab_main"])
            #expect(fixture.provider.tabRenames == ["Calculate 2+2"])
            fixture.install(try fixture.state(revision: 2, name: "Calculate 2+2"))
            fixture.reconcile()
            try fixture.assertParity("Calculate 2+2")
            #expect(workspace.panelCustomTitleSources[fixture.panelID] == .auto)
            // Cmd+R's shared action resolves the workspace UUID, never its old title.
            #expect(manager.setCustomTitle(tabId: workspace.id, title: "Review / 本番"))
            try await fixture.drain()
            #expect(fixture.provider.workspaceRenames == ["Review / 本番"])
            fixture.install(try fixture.state(revision: 3, name: "Calculate 2+2", workspaceName: "Review / 本番"))
            fixture.reconcile()
            #expect(workspace.title == "Review / 本番")
            try fixture.assertParity("Calculate 2+2", workspaceName: "Review / 本番")
        }
    }

    @Test("A user label wins whether selected before or after the agent title", arguments: [false, true])
    func cloudUserAndAgentRenameOrders(userFirst: Bool) async throws {
        try await withManagerAsync { manager, workspace in
            let fixture = try CloudSidebarRenameFixture(manager: manager, workspace: workspace, catalog: .shared)
            defer { fixture.close() }
            if userFirst { #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Arbitrary / 名前")) }
            _ = try await callAsync(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString, "panel_id": fixture.panelID.uuidString, "title": "Calculate 2+2"
            ])
            if !userFirst { #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Arbitrary / 名前")) }
            try await fixture.drain()
            #expect(fixture.provider.tabRenames.last == "Arbitrary / 名前")
            fixture.install(try fixture.state(revision: 4, name: "Arbitrary / 名前"))
            fixture.reconcile()
            _ = try await callAsync(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString, "panel_id": fixture.panelID.uuidString, "title": "Delayed old task"
            ])
            try await fixture.drain()
            fixture.install(try fixture.state(revision: 1, generation: "reconnected", name: "Arbitrary / 名前"))
            fixture.reconcile()
            try fixture.assertParity("Arbitrary / 名前")
            #expect(workspace.panelCustomTitleSources[fixture.panelID] == .user)
        }
    }

    @Test("An exact tab ID resolves Cmd+R ownership when one terminal has several workspace placements")
    func exactTabSelectsWorkspaceOwnership() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        var resource = fixture.snapshot().resources[0]
        let other = try #require(fixture.snapshot().resources[1].remoteViews?.first)
        resource.remoteViews?.append(other)
        let projection = SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID(), remoteTabID: other.tabID)
        let target = CloudWorkspaceRenameService().inferredRemoteWorkspaceTarget(projections: [projection], resources: [resource])
        #expect(target?.machine == fixture.machine)
        #expect(target?.remoteWorkspaceID == other.workspace.id)
    }
}
