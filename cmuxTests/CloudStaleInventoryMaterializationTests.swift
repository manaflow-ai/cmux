import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud stale inventory admission", .serialized, .exclusiveAppContext)
struct CloudStaleInventoryMaterializationTests {
    @Test("a stale graph never materializes an interactive restored terminal")
    func staleGraphIsNotInteractive() {
        #expect(CmuxTuiSurfaceProvider.shouldShowRecoverableCloudFailure(observation: .stale(reason: "link timeout")))
        #expect(!CmuxTuiSurfaceProvider.shouldShowRecoverableCloudFailure(observation: .current))
    }

    @Test("missing and stale observations fail the actual attachment and fresh state retries it", arguments: [false, true])
    func restoredAttachmentRecovers(hasStaleObservation: Bool) throws {
        _ = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        manager.selectedTabId = workspace.id
        defer { workspace.teardownAllPanels(); manager.tabs = [] }
        try LiveWorkspaceFixture.withAppRegistration(of: manager) {
            let panelID = try #require(workspace.focusedPanelId)
            let catalog = SurfaceCatalog()
            let summary = VMSummary(id: "stale-\(UUID())", provider: "freestyle", status: "running", image: "fixture", createdAt: 0, base: nil)
            let provider = CmuxTuiSurfaceProvider(summary: summary,
                links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }), catalog: catalog)
            catalog.register(provider)
            defer { provider.suspendForFeatureFlag(); catalog.unregister(machine: provider.machine) }
            let resource = SurfaceResource(id: .init(machine: provider.machine, kind: .terminal, key: "term_fixture"), title: "Terminal", lifecycle: .running)
            let state = CloudVMState(machine: provider.machine, cursor: nil, rawSnapshot: Data("{}".utf8),
                workspaces: [], screens: [], panes: [], tabs: [], terminals: [], browsers: [], agents: [])
            if hasStaleObservation {
                catalog.replaceCloudState(state, resources: [resource], info: provider.info, observation: .stale(reason: "link timeout"))
            }
            let reservation = CloudTerminalPaneReservation(workspaceID: workspace.id, panelID: panelID, machine: provider.machine)
            workspace.cloudPendingCreations[panelID] = reservation
            defer { reservation.cancel?(); workspace.cloudPendingCreations[panelID] = nil }
            provider.attachReservedTerminalPane(reservation, resource: resource, remoteTabID: nil)
            #expect(workspace.cloudMaterializationFailures[panelID] != nil)
            #expect(!provider.materializedPanels.contains(panelID))
            #expect(provider.restoredAttachTasks[panelID] == nil)
            #expect(workspace.retryReservedCloudTerminalPane(surfaceId: panelID))
            #expect(!provider.materializedPanels.contains(panelID))

            catalog.record(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: panelID))
            catalog.replaceCloudState(state, resources: [resource], info: provider.info, observation: .current)
            provider.projectionsRestored()
            #expect(provider.materializedPanels.contains(panelID))
            #expect(provider.restoredAttachTasks[panelID] != nil)
        }
    }

    // https://github.com/manaflow-ai/cmux/issues/21820: when every status read
    // answered 404 the pane stayed reserved with no card, so a machine that
    // never connected looked like a blank terminal that swallowed input.
    @Test(
        "a restored terminal whose machine answers 404 explains itself, keeps its link, and recovers",
        arguments: [nil, "team-saved"] as [String?]
    )
    func restoredMachineNotFoundShowsCard(savedTeam: String?) async throws {
        let app = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        manager.selectedTabId = workspace.id
        let windowID = app.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            app.forgetRecoverableMainWindowRoute(windowId: windowID)
            workspace.teardownAllPanels()
            manager.tabs = []
        }
        let panelID = try #require(workspace.focusedPanelId)
        let machineID = "restored-\(UUID())"
        let machine = SurfaceMachineID.cloud(machineID)
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_fixture")
        let catalog = SurfaceCatalog()
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: resource)], workspaceID: workspace.id)
        let reservation = CloudTerminalPaneReservation(
            workspaceID: workspace.id, panelID: panelID, machine: machine,
            attachmentPlacement: SurfaceResourcePlacement(resource: resource, remoteWorkspaceID: nil, remoteTabID: nil)
        )
        workspace.cloudPendingCreations[panelID] = reservation
        defer { reservation.cancel?(); workspace.cloudPendingCreations[panelID] = nil }

        var machineFound = false
        var statusReads = 0
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: [], limits: nil) },
            activeTeamID: { "team-a" },
            loadMachineStatus: { id, _ in
                statusReads += 1
                guard machineFound else { throw VMClientError.httpStatus(404, #"{"error":"vm_not_found"}"#) }
                return VMSummary(id: id, provider: "freestyle", status: "running", image: "fixture", createdAt: 0, base: nil)
            },
            refreshProvider: { _, _ in true }
        )
        registry.adoptOwnerTeam(savedTeam, forMachineID: machineID)
        registry.start(catalog: catalog)

        // Both reads failed: the pane says so, and its saved link is untouched.
        #expect(await registry.refresh(force: true))
        #expect(registry.provider(machineID: machineID) == nil)
        #expect(catalog.pendingRestoredMachineIDs == [machineID])
        #expect(catalog.projectionRecords(forWorkspace: workspace.id).map(\.resource) == [resource])
        let failure = try #require(workspace.cloudMaterializationFailures[panelID])
        #expect(failure.detail == CloudTuiManualMirrorStopReason.accessLost.endedPresentation?.detail)
        let card = try #require(workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: panelID))
        #expect(card.showsReconnectButton)

        // Reconnect reads again, and the card stays until a read finds the machine.
        let readsBeforeReconnect = statusReads
        #expect(workspace.retryReservedCloudTerminalPane(surfaceId: panelID))
        #expect(workspace.cloudMaterializationFailures[panelID] != nil)
        #expect(await registry.refresh(force: true))
        #expect(statusReads > readsBeforeReconnect)
        #expect(workspace.cloudMaterializationFailures[panelID] != nil)

        // The machine is found: the card leaves as soon as the provider registers,
        // whether or not its terminal can attach yet.
        machineFound = true
        #expect(await registry.refresh(force: true))
        let provider = try #require(registry.provider(machineID: machineID))
        #expect(workspace.cloudMaterializationFailures[panelID] == nil)

        // A later 404 reaches the pane through the provider, and a listing clears it.
        provider.noteAccessLost(.notFound)
        #expect(workspace.cloudMaterializationFailures[panelID] != nil)
        #expect(workspace.retryReservedCloudTerminalPane(surfaceId: panelID))
        #expect(workspace.cloudMaterializationFailures[panelID] != nil)
        provider.noteAccessConfirmed()
        #expect(workspace.cloudMaterializationFailures[panelID] == nil)

        // The saved link is still there for the attachment.
        #expect(catalog.projectionRecords(forWorkspace: workspace.id).map(\.resource) == [resource])
        catalog.replaceCloudState(
            CloudVMState(machine: machine, cursor: nil, rawSnapshot: Data("{}".utf8),
                workspaces: [], screens: [], panes: [], tabs: [], terminals: [], browsers: [], agents: []),
            resources: [SurfaceResource(id: resource, title: "Terminal", lifecycle: .running)],
            info: provider.info, observation: .current
        )
        #expect(workspace.cloudMaterializationFailures[panelID] == nil)
        await registry.accessDidEnd()
    }

    @Test("a restored terminal whose machine answers 403 keeps a card when its panes leave")
    func restoredMachineForbiddenShowsCard() async throws {
        let app = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        manager.selectedTabId = workspace.id
        let windowID = app.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            app.forgetRecoverableMainWindowRoute(windowId: windowID)
            workspace.teardownAllPanels()
            manager.tabs = []
        }
        let panelID = try #require(workspace.focusedPanelId)
        let machineID = "restored-\(UUID())"
        let machine = SurfaceMachineID.cloud(machineID)
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_fixture")
        let catalog = SurfaceCatalog()
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: resource)], workspaceID: workspace.id)
        let reservation = CloudTerminalPaneReservation(
            workspaceID: workspace.id, panelID: panelID, machine: machine,
            attachmentPlacement: SurfaceResourcePlacement(resource: resource, remoteWorkspaceID: nil, remoteTabID: nil)
        )
        workspace.cloudPendingCreations[panelID] = reservation
        defer { workspace.cloudPendingCreations[panelID] = nil }
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: [], limits: nil) },
            activeTeamID: { "team-a" },
            loadMachineStatus: { _, _ in throw VMClientError.httpStatus(403, #"{"error":"forbidden"}"#) },
            refreshProvider: { _, _ in true }
        )
        registry.start(catalog: catalog)

        #expect(await registry.refresh(force: true))
        #expect(catalog.pendingRestoredMachineIDs.isEmpty)
        #expect(workspace.cloudMaterializationFailures[panelID] != nil)
        await registry.accessDidEnd()
    }
}
