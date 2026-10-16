import CmuxSurfaceCatalogModel
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
            let probe = try await callAsync(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString, "panel_id": fixture.panelID.uuidString, "probe": true
            ])
            let context = try #require((probe["result"] as? [String: Any])?["cloud_name_context"] as? [String: Any])
            let response = try await callAsync(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString,
                "panel_id": fixture.panelID.uuidString,
                "title": "Calculate 2+2", "cloud_name_context": context
            ])
            #expect(response["ok"] as? Bool == true)
            #expect((response["result"] as? [String: Any])?["applied"] as? Bool == true)
            try await fixture.drain()
            #expect(fixture.provider.renamedTabs.map(\.id) == ["tab_main"])
            #expect(fixture.provider.tabRenames == ["Calculate 2+2"])
            fixture.install(try fixture.state(revision: 2, name: "Calculate 2+2", nameSource: "auto"))
            fixture.reconcile()
            try fixture.assertParity("Calculate 2+2")
            #expect(workspace.panelCustomTitleSources[fixture.panelID] == .remote)
            #expect(fixture.catalog.cloudStates[fixture.machine]?.lookupIndex.tab(id: "tab_main")?.nameAuthority?.source == .auto)
            // Cmd+R's shared action resolves the workspace UUID, never its old title.
            #expect(manager.setCustomTitle(tabId: workspace.id, title: "Review / 本番"))
            try await fixture.drain()
            #expect(fixture.provider.workspaceRenames == ["Review / 本番"])
            fixture.install(try fixture.state(revision: 3, name: "Calculate 2+2", workspaceName: "Review / 本番", nameSource: "auto"))
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
            let context = try #require(fixture.catalog.cloudAgentNameContext(workspaceID: workspace.id, panelID: fixture.panelID)?.wire)
            if userFirst {
                #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Arbitrary / 名前"))
                try await fixture.drain()
                fixture.install(try fixture.state(revision: 2, name: "Arbitrary / 名前", nameSource: "user"))
                fixture.reconcile()
            }
            let agent = try await callAsync(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString, "panel_id": fixture.panelID.uuidString,
                "title": "Calculate 2+2", "cloud_name_context": context
            ])
            #expect((agent["result"] as? [String: Any])?["applied"] as? Bool == !userFirst)
            if !userFirst { #expect(workspace.setPanelCustomTitle(panelId: fixture.panelID, title: "Arbitrary / 名前")) }
            try await fixture.drain()
            #expect(fixture.provider.tabRenames.last == "Arbitrary / 名前")
            fixture.install(try fixture.state(revision: 4, name: "Arbitrary / 名前", nameSource: "user"))
            fixture.reconcile()
            let delayed = try await callAsync(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString, "panel_id": fixture.panelID.uuidString,
                "title": "Delayed old task", "cloud_name_context": context
            ])
            #expect((delayed["result"] as? [String: Any])?["applied"] as? Bool == false)
            try await fixture.drain()
            fixture.install(try fixture.state(revision: 1, generation: "reconnected", name: "Arbitrary / 名前", nameSource: "user"))
            fixture.reconcile()
            try fixture.assertParity("Arbitrary / 名前")
            #expect(workspace.panelCustomTitleSources[fixture.panelID] == .remote)
            #expect(fixture.catalog.cloudStates[fixture.machine]?.lookupIndex.tab(id: "tab_main")?.nameAuthority?.source == .user)
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
