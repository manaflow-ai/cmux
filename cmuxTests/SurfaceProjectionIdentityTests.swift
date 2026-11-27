import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises live identity owners, the query capture, and the public JSON serializer.
/// Runtime selectors remain separate from the restart-stable read-only join.
@MainActor
@Suite(.serialized)
struct SurfaceProjectionIdentityTests {
    @Test("Catalog identity comes from current owners without renaming runtime selectors")
    func ownerIdentityPreservesRuntimeSelectors() async throws {
        try await withWorkspaces(count: 1) { workspaces in
            let workspace = workspaces[0]
            let panel = try terminal(in: workspace)
            let stableID = UUID()
            panel.adoptStableSurfaceId(stableID)
            let catalog = await localCatalog(workspaces)
            let export = await read(catalog, workspaces: workspaces)
            let row = try projectionRow(export, panelID: panel.id)
            #expect(stableID != panel.id)
            #expect(row["stable_surface_id"] as? String == stableID.uuidString)
            #expect(row["stable_workspace_id"] as? String == workspace.stableId.uuidString)
            #expect(row["panel_id"] as? String == panel.id.uuidString)
            #expect(row["surface_id"] as? String == panel.id.uuidString)
            #expect(row["workspace_id"] as? String == workspace.id.uuidString)
            let resourceID = LocalSurfaceProvider.resourceID(forTerminalPanel: panel.id)
            #expect(row["resource"] as? String == resourceID.rawValue)
            let payload = try jsonPayload(export)
            let resources = try #require(payload["resources"] as? [[String: Any]])
            let resource = try #require(resources.first { $0["id"] as? String == resourceID.rawValue })
            #expect(resource["key"] as? String == panel.id.uuidString)
            #expect(resource["open_surface_ids"] as? [String] == [panel.id.uuidString])
            #expect(resource["open_workspace_ids"] as? [String] == [workspace.id.uuidString])
        }
    }

    @Test("Serialization uses the captured owner identity even after the owner changes")
    func serializationDoesNotRequeryOwners() async throws {
        try await withWorkspaces(count: 1) { workspaces in
            let panel = try terminal(in: workspaces[0])
            let before = panel.stableSurfaceId
            let catalog = await localCatalog(workspaces)
            let captured = await read(catalog, workspaces: workspaces)
            let after = UUID()
            panel.adoptStableSurfaceId(after)
            #expect(try projectionRow(captured, panelID: panel.id)["stable_surface_id"] as? String == before.uuidString)
            let refreshed = await read(catalog, workspaces: workspaces)
            #expect(try projectionRow(refreshed, panelID: panel.id)["stable_surface_id"] as? String == after.uuidString)
        }
    }

    @Test("Moving a live pane retains surface identity and changes its workspace identity")
    func movingPaneUpdatesOnlyItsOwnerJoin() async throws {
        try await withWorkspaces(count: 2) { workspaces in
            let source = workspaces[0], destination = workspaces[1]
            let panel = try terminal(in: source)
            let stableID = panel.stableSurfaceId
            let catalog = await localCatalog(workspaces)
            let before = await read(catalog, workspaces: workspaces)
            let detached = try #require(source.detachSurface(panelId: panel.id))
            let targetPane = try #require(destination.bonsplitController.allPaneIds.first)
            #expect(destination.attachDetachedSurface(detached, inPane: targetPane) != nil)
            // The workspace hooks target the shared catalog; feed the same owner hook
            // to this test's isolated provider/catalog.
            let provider = LocalSurfaceProvider(catalog: catalog, workspaces: { workspaces })
            provider.panelDidAppear(panel, in: destination)
            let after = await read(catalog, workspaces: workspaces)
            let row = try projectionRow(after, panelID: panel.id)
            #expect(row["stable_surface_id"] as? String == stableID.uuidString)
            #expect(row["stable_workspace_id"] as? String == destination.stableId.uuidString)
            #expect(row["workspace_id"] as? String == destination.id.uuidString)
            #expect(row["resource"] as? String == LocalSurfaceProvider.resourceID(forTerminalPanel: panel.id).rawValue)
            #expect(try projectionRow(before, panelID: panel.id)["stable_workspace_id"] as? String == source.stableId.uuidString)
        }
    }

    @Test("Restore exposes a new runtime binding to the persisted stable owners")
    func restoreRejoinsPersistedIdentity() async throws {
        try await withWorkspaces(count: 2) { workspaces in
            let source = workspaces[0], restored = workspaces[1]
            let panel = try terminal(in: source)
            let oldPanelID = panel.id, stableID = panel.stableSurfaceId
            let stableWorkspaceID = source.stableId
            let snapshot = source.sessionSnapshot(includeScrollback: false)
            // A non-colliding restore represents reopening after the old pane closes.
            for id in Array(source.panels.keys) { _ = source.closePanel(id, force: true) }
            let remapped = restored.restoreSessionSnapshot(snapshot)
            let newPanelID = try #require(remapped[oldPanelID])
            // The persisted runtime id is reused whenever no live surface still holds it
            // (aff0e32e93): the panel id is the ghostty surface id, so agent bindings survive
            // relaunch. Only a collision mints a fresh id; either way the pane must be live.
            #expect(restored.panels[newPanelID] != nil)
            let catalog = await localCatalog([restored])
            let export = await read(catalog, workspaces: [restored])
            let row = try projectionRow(export, panelID: newPanelID)
            #expect(row["stable_surface_id"] as? String == stableID.uuidString)
            #expect(row["stable_workspace_id"] as? String == stableWorkspaceID.uuidString)
            #expect(row["surface_id"] as? String == newPanelID.uuidString)
            #expect(row["workspace_id"] as? String == restored.id.uuidString)
            #expect(row["resource"] as? String == LocalSurfaceProvider.resourceID(forTerminalPanel: newPanelID).rawValue)
        }
    }

    @Test("A colliding restore publishes the owner's fresh stable identity")
    func collidingRestoreDoesNotPublishDuplicateIdentity() async throws {
        try await withWorkspaces(count: 2) { workspaces in
            let source = workspaces[0], restored = workspaces[1]
            let original = try terminal(in: source)
            let snapshot = source.sessionSnapshot(includeScrollback: false)
            let remapped = restored.restoreSessionSnapshot(
                snapshot, excludingStableIdentities: [source.stableId, original.stableSurfaceId]
            )
            let newPanelID = try #require(remapped[original.id])
            let newPanel = try #require(restored.panels[newPanelID])
            #expect(newPanel.stableSurfaceId != original.stableSurfaceId)
            #expect(restored.stableId != source.stableId)
            let catalog = await localCatalog(workspaces)
            let export = await read(catalog, workspaces: workspaces)
            let row = try projectionRow(export, panelID: newPanelID)
            #expect(row["stable_surface_id"] as? String == newPanel.stableSurfaceId.uuidString)
            #expect(row["stable_workspace_id"] as? String == restored.stableId.uuidString)
        }
    }

    @Test("Missing or mismatched current owners emit null rather than guessed identity")
    func missingAndMismatchedOwnersRemainUnknown() async throws {
        try await withWorkspaces(count: 2) { workspaces in
            let workspace = workspaces[0], wrongWorkspace = workspaces[1]
            let panel = try terminal(in: workspace)
            let catalog = await localCatalog([workspace])
            let projection = try #require(catalog.projection(forPanel: panel.id))
            for owner in [nil, wrongWorkspace] as [Workspace?] {
                let query = SurfaceCatalogQueryService(
                    catalog: catalog,
                    projectionIdentities: { projections in
                        SurfaceProjectionIdentity.capture(
                            projections: projections,
                            workspacesByID: owner.map { [workspace.id: $0] } ?? [:]
                        )
                    },
                    discoverCloudMachine: { _ in Issue.record("A cached identity read must not discover Cloud") }
                )
                let export = await query.read(machine: nil, refresh: false)
                let row = try projectionRow(export, panelID: panel.id)
                #expect(row["stable_surface_id"] is NSNull)
                #expect(row["stable_workspace_id"] is NSNull)
            }
            // A matching dictionary key is insufficient if it contains another owner.
            let otherPanel = try terminal(in: wrongWorkspace)
            workspace.panels[panel.id] = otherPanel
            #expect(SurfaceProjectionIdentity(projection: projection, workspace: workspace) == nil)
            let mismatched = await read(catalog, workspaces: [workspace])
            let mismatchedRow = try projectionRow(mismatched, panelID: panel.id)
            #expect(mismatchedRow["stable_surface_id"] is NSNull)
            #expect(mismatchedRow["stable_workspace_id"] is NSNull)
            workspace.panels[panel.id] = panel
            _ = workspace.closePanel(panel.id, force: true)
            let export = await read(catalog, workspaces: [workspace])
            let row = try projectionRow(export, panelID: panel.id)
            #expect(row["stable_surface_id"] is NSNull)
            #expect(row["stable_workspace_id"] is NSNull)
        }
    }

    @Test("Cloud mirror identity describes local owners without changing daemon identity")
    func cloudMirrorKeepsDaemonIdentitySeparate() async throws {
        try await withWorkspaces(count: 1) { workspaces in
            let workspace = workspaces[0]
            let panel = try terminal(in: workspace)
            let catalog = await localCatalog(workspaces)
            let machine = SurfaceMachineID.cloud("identity-fixture")
            // The catalog ignores writes about a Cloud machine with no registered provider
            // (a22bde65ad), so register the fixture provider before publishing its resource.
            let provider = try CloudCatalogQueryTestProvider(machine: machine, catalog: catalog)
            catalog.register(provider)
            let resourceID = SurfaceResourceID(machine: machine, kind: .terminal, key: "daemon-terminal")
            let resource = SurfaceResource(id: resourceID, title: "same title", detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
            var info = LocalSurfaceProvider(catalog: catalog, workspaces: { workspaces }).info
            info.id = machine
            info.linkState = .connected
            catalog.replaceResources([resource], on: machine, info: info, from: provider)
            catalog.record(SurfaceProjection(resource: resourceID, workspaceID: workspace.id, panelID: panel.id, remoteWorkspaceID: "daemon-workspace", remoteTabID: "daemon-tab"))
            let export = await read(catalog, workspaces: workspaces)
            for cloudOnly in [false, true] {
                let row = try projectionRow(export, panelID: panel.id, cloudOnly: cloudOnly)
                #expect(row["stable_surface_id"] as? String == panel.stableSurfaceId.uuidString)
                #expect(row["stable_workspace_id"] as? String == workspace.stableId.uuidString)
                #expect(row["resource"] as? String == resourceID.rawValue)
                #expect(row["remote_workspace_id"] as? String == "daemon-workspace")
                #expect(row["remote_tab_id"] as? String == "daemon-tab")
            }
        }
    }

    @Test("Identical labels and directories do not merge distinct stable owners")
    func sameMetadataDoesNotImplySameIdentity() async throws {
        try await withWorkspaces(count: 2) { workspaces in
            let first = try terminal(in: workspaces[0])
            let second = try terminal(in: workspaces[1])
            for (workspace, panel) in [(workspaces[0], first), (workspaces[1], second)] {
                workspace.panelTitles[panel.id] = "same work"
                workspace.panelDirectories[panel.id] = "/tmp/cmux-identity-fixture"
            }
            let catalog = await localCatalog(workspaces)
            let export = await read(catalog, workspaces: workspaces)
            let firstRow = try projectionRow(export, panelID: first.id)
            let secondRow = try projectionRow(export, panelID: second.id)
            #expect(firstRow["stable_surface_id"] as? String == first.stableSurfaceId.uuidString)
            #expect(secondRow["stable_surface_id"] as? String == second.stableSurfaceId.uuidString)
            #expect(first.stableSurfaceId != second.stableSurfaceId)
            #expect(firstRow["stable_workspace_id"] as? String != secondRow["stable_workspace_id"] as? String)
        }
    }

    @Test("A read captures owner identities once after optional discovery and refresh")
    func batchCaptureUsesOwnersAfterRefresh() async throws {
        try await withWorkspaces(count: 2) { workspaces in
            let catalog = await localCatalog(workspaces)
            let machine = SurfaceMachineID.cloud("identity-capture-order")
            let provider = try CloudCatalogQueryTestProvider(machine: machine, catalog: catalog)
            var refreshedOwnerIndex: [UUID: Workspace] = [:]
            var captures = 0
            let query = SurfaceCatalogQueryService(
                catalog: catalog,
                projectionIdentities: { projections in
                    captures += 1
                    #expect(refreshedOwnerIndex.count == workspaces.count)
                    #expect(projections.count == workspaces.count)
                    #expect(provider.forcedRefreshes == [true])
                    return SurfaceProjectionIdentity.capture(projections: projections, workspacesByID: refreshedOwnerIndex)
                },
                discoverCloudMachine: { _ in
                    await Task.yield()
                    refreshedOwnerIndex = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
                    catalog.register(provider)
                }
            )
            let export = await query.read(machine: machine, refresh: true)
            #expect(captures == 1)
            #expect(export.projectionIdentities.count == workspaces.count)
        }
    }

    @Test("The owner index preserves registered precedence over an active duplicate")
    func ownerIndexMatchesWorkspaceLookup() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousDelegate = AppDelegate.shared
            let app = AppDelegate()
            let registered = TabManager()
            let active = TabManager()
            let registeredWorkspace = try #require(registered.tabs.first)
            let duplicate = Workspace(id: registeredWorkspace.id)
            active.tabs.append(duplicate)
            let activeOnly = try #require(active.tabs.first)
            let windowID = app.registerMainWindowContextForTesting(tabManager: registered)
            app.tabManager = active
            defer {
                app.unregisterMainWindowContextForTesting(windowId: windowID)
                app.tabManager = nil
                for manager in [registered, active] {
                    for workspace in Array(manager.tabs) {
                        manager.closeWorkspace(workspace, recordHistory: false)
                    }
                }
                AppDelegate.shared = previousDelegate
            }
            let missingID = UUID()
            let ids: Set<UUID> = [registeredWorkspace.id, activeOnly.id, missingID]
            let owners = app.workspacesForRead(tabIds: ids)
            #expect(owners[registeredWorkspace.id] === registeredWorkspace)
            #expect(owners[registeredWorkspace.id] !== duplicate)
            #expect(owners[activeOnly.id] === activeOnly)
            #expect(owners[missingID] == nil)
            for id in ids {
                #expect(owners[id] === app.workspaceFor(tabId: id))
            }
            // The selected registered owner lacks this active duplicate's panel.
            // Do not search the fallback owner for a more convenient identity.
            let duplicatePanel = try terminal(in: duplicate)
            let projection = SurfaceProjection(
                resource: LocalSurfaceProvider.resourceID(forTerminalPanel: duplicatePanel.id),
                workspaceID: duplicate.id,
                panelID: duplicatePanel.id
            )
            #expect(SurfaceProjectionIdentity.capture(projections: [projection], workspacesByID: owners).isEmpty)
            // A windowless orphan cannot supply a live owner. The active
            // manager remains the fallback, just as in workspaceFor(tabId:).
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            app.tabManager = active
            let afterUnregister = app.workspacesForRead(tabIds: ids)
            #expect(afterUnregister[registeredWorkspace.id] === duplicate)
            #expect(afterUnregister[registeredWorkspace.id] === app.workspaceFor(tabId: registeredWorkspace.id))
        }
    }

    private func withWorkspaces(count: Int, body: @MainActor ([Workspace]) async throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let manager = TabManager()
            let workspaces = (0..<count).map { _ in manager.addWorkspace(select: false) }
            defer {
                for workspace in Array(manager.tabs) {
                    manager.closeWorkspace(workspace, recordHistory: false)
                }
            }
            try await body(workspaces)
        }
    }

    private func terminal(in workspace: Workspace) throws -> TerminalPanel {
        try #require(workspace.panels.values.compactMap { $0 as? TerminalPanel }.first)
    }

    private func localCatalog(_ workspaces: [Workspace]) async -> SurfaceCatalog {
        let catalog = SurfaceCatalog()
        let provider = LocalSurfaceProvider(catalog: catalog, workspaces: { workspaces })
        catalog.register(provider)
        await provider.refresh()
        return catalog
    }

    private func read(_ catalog: SurfaceCatalog, workspaces: [Workspace]) async -> SurfaceCatalogExport {
        let query = SurfaceCatalogQueryService(
            catalog: catalog,
            projectionIdentities: { projections in
                SurfaceProjectionIdentity.capture(
                    projections: projections,
                    workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
                )
            },
            discoverCloudMachine: { _ in Issue.record("A cached identity read must not discover Cloud") }
        )
        return await query.read(machine: nil, refresh: false)
    }

    private func jsonPayload(_ export: SurfaceCatalogExport, cloudOnly: Bool = false) throws -> [String: Any] {
        let payload = TerminalController.surfaceCatalogPayload(export, machine: nil, cloudOnly: cloudOnly)
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func projectionRow(_ export: SurfaceCatalogExport, panelID: UUID, cloudOnly: Bool = false) throws -> [String: Any] {
        let rows = try #require(jsonPayload(export, cloudOnly: cloudOnly)["projections"] as? [[String: Any]])
        return try #require(rows.first { $0["panel_id"] as? String == panelID.uuidString })
    }
}
