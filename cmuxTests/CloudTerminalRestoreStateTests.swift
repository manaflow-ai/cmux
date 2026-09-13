import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud terminal restore state", .serialized)
struct CloudTerminalRestoreStateTests {
    @Test
    func savedCloudIdentityShowsStateBeforeTheProviderHasDiscoveredIt() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let machine = SurfaceMachineID.cloud("restore-fixture-" + UUID().uuidString)
        let catalog = SurfaceCatalog.shared
        defer { catalog.unregister(machine: machine) }
        catalog.restore([SurfaceProjectionRecord(
            panelID: panelID,
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_saved"),
            remoteWorkspaceID: "ws_saved", remoteTabID: "tab_saved"
        )], workspaceID: workspace.id)

        let waiting = try #require(workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: panelID))
        #expect(waiting.showsProgress)
        workspace.setCloudMaterializationFailure(surfaceID: panelID, detail: "Endpoint unavailable", reference: nil)
        let failed = try #require(workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: panelID))
        #expect(failed.showsReconnectButton)
        #expect(!failed.showsProgress)
        workspace.clearCloudMaterializationFailure(surfaceID: panelID)
        #expect(workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: panelID)?.showsProgress == true)

        let removed = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "g", "revision": "2"],
            "workspaces": [], "screens": [], "panes": [], "tabs": [],
            "terminals": [["id": "term_saved", "lifecycle": "running"]], "browsers": [], "agents": []
        ], machine: machine))
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.replaceCloudState(removed, resources: CmuxTuiSnapshotParser.resources(from: removed), info: provider.info)
        let missing = try #require(workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: panelID))
        #expect(missing.showsReconnectButton)
        #expect(!missing.showsProgress, "an authoritative missing tab is not an endless connection spinner")
    }
}
