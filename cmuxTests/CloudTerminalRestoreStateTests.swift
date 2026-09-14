import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud terminal restore state")
struct CloudTerminalRestoreStateTests {
    @Test
    func savedCloudIdentityShowsStateBeforeTheProviderHasDiscoveredIt() throws {
        let workspaceID = UUID(), panelID = UUID()
        let machine = SurfaceMachineID.cloud("restore-fixture")
        let catalog = SurfaceCatalog()
        // Restore constructs a local scaffold before Cloud discovery. Its live
        // local entry must not hide the saved remote identity's presentation.
        catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: .local, kind: .terminal, key: panelID.uuidString),
            workspaceID: workspaceID, panelID: panelID
        ))
        let saved = SurfaceProjectionRecord(
            panelID: panelID,
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_saved"),
            remoteWorkspaceID: "ws_saved", remoteTabID: "tab_saved"
        )
        catalog.restore([saved], workspaceID: workspaceID)
        #expect(catalog.projectionIdentity(forPanel: panelID, in: workspaceID) == saved)
        #expect(catalog.projectionIdentity(forPanel: panelID, in: UUID()) == nil)
        let waiting = try #require(CloudTerminalMaterializationPresentation(machine: nil, identity: saved).presentation)
        #expect(waiting.showsProgress)
        let failed = Workspace.cloudMaterializationFailurePresentation(detail: "Endpoint unavailable", reference: nil)
        #expect(failed.showsReconnectButton)
        #expect(!failed.showsProgress)

        let removed = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "g", "revision": "2"],
            "workspaces": [], "screens": [], "panes": [], "tabs": [],
            "terminals": [["id": "term_saved", "lifecycle": "running"]], "browsers": [], "agents": []
        ], machine: machine))
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.replaceCloudState(removed, resources: CmuxTuiSnapshotParser.resources(from: removed), info: provider.info)
        let identity = try #require(catalog.projectionIdentity(forPanel: panelID, in: workspaceID))
        let missing = try #require(CloudTerminalMaterializationPresentation(
            machine: provider.info, identity: identity, graph: catalog.cloudStates[machine], graphIsCurrent: true
        ).presentation)
        #expect(missing.showsReconnectButton)
        #expect(!missing.showsProgress, "an authoritative missing tab is not an endless connection spinner")
    }
}
