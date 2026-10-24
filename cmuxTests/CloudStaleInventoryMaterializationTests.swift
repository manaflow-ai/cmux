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

    @Test("a restored attachment stops retrying after showing Reconnect")
    func restoredAttachmentStopsAfterRecoverableFailures() async throws {
        _ = try #require(AppDelegate.shared)
        let clock = SidebarTestManualClock()
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        manager.selectedTabId = workspace.id
        defer { workspace.teardownAllPanels(); manager.tabs = [] }
        try await LiveWorkspaceFixture.withAppRegistration(of: manager) {
            let panelID = try #require(workspace.focusedPanelId)
            let catalog = SurfaceCatalog()
            let summary = VMSummary(id: "retry-stop-\(UUID())", provider: "freestyle", status: "running", image: "fixture", createdAt: 0, base: nil)
            let provider = CmuxTuiSurfaceProvider(
                summary: .cloud(summary),
                links: ImmediateUnavailableLinks(),
                catalog: catalog,
                attachmentClock: clock
            )
            catalog.register(provider)
            defer { provider.suspendForFeatureFlag(); catalog.unregister(machine: provider.machine) }
            let resource = SurfaceResource(
                id: .init(machine: provider.machine, kind: .terminal, key: "term_fixture"),
                title: "Terminal", lifecycle: .running
            )
            let state = CloudVMState(
                machine: provider.machine, cursor: nil, rawSnapshot: Data("{}".utf8),
                workspaces: [], screens: [], panes: [], tabs: [], terminals: [], browsers: [], agents: []
            )
            catalog.replaceCloudState(state, resources: [resource], info: provider.info, observation: .current)
            let reservation = CloudTerminalPaneReservation(
                workspaceID: workspace.id, panelID: panelID, machine: provider.machine
            )
            workspace.cloudPendingCreations[panelID] = reservation
            defer { reservation.cancel?(); workspace.cloudPendingCreations[panelID] = nil }

            provider.attachReservedTerminalPane(reservation, resource: resource, remoteTabID: nil)
            for delay in CloudTerminalAttachmentRetryPolicy.background.delays.prefix(3) {
                await clock.waitUntilSleeping(for: delay)
                clock.advance(by: delay)
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while workspace.cloudMaterializationFailures[panelID] == nil,
                  ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }

            #expect(workspace.cloudMaterializationFailures[panelID] != nil)
            #expect(provider.restoredAttachTasks[panelID] == nil)
            #expect(!provider.materializedPanels.contains(panelID))
        }
    }

}

private actor ImmediateUnavailableLinks: RemoteTuiLinkManaging {
    nonisolated let operations: CloudOperationRecorder? = nil

    func connected(machineID: String) async throws -> CloudMachineLink.Connected {
        throw URLError(.cannotConnectToHost)
    }

    func link(machineID: String) async -> CloudMachineLink? { nil }
    func status(machineID: String) async -> CloudMachineLinkManager.LinkStatus? { nil }
    func privateAddresses(for machineID: String) async -> [String] { [] }
    func setPrivateAddresses(_ addresses: [String], for machineID: String) async {}
    func browserProxy(machineID: String, remoteNetwork: Bool) async throws -> CloudBrowserProxyEndpoint {
        throw URLError(.cannotConnectToHost)
    }
}
