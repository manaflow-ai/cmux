import CmuxCloud
import AppKit
import Foundation
import SwiftUI
import CmuxCloudMachines
import CmuxSurfaceCatalogModel
import Testing
import Observation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud mutation receipt reconciliation")
struct CloudMutationReceiptReconciliationTests {
    @Test("Cloud mutation receipts reject stale and conflicting graphs")
    func cloudMutationReceiptsRejectStaleAndConflictingGraphs() {
        let receipt = CloudVMCursor(generation: "daemon-a", revision: 8)

        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: nil,
                targetMatches: true
            ) == .rejectStale
        )
        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: CloudVMCursor(generation: "daemon-a", revision: 7),
                targetMatches: true
            ) == .rejectStale
        )
        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: receipt,
                targetMatches: false
            ) == .rejectConflict
        )
        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: receipt,
                targetMatches: true
            ) == .accept
        )
        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: CloudVMCursor(generation: "daemon-a", revision: 9),
                targetMatches: false
            ) == .accept
        )
    }

    @Test("Canonical cloud state survives a cursorless status refresh")
    @MainActor
    func canonicalCloudStateSurvivesCursorlessStatusRefresh() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = CloudTreeCatalogFakeProvider(machine: machine)
        catalog.register(provider)

        let snapshot: [String: Any] = [
            "cursor": ["generation": "g1", "revision": "2"],
            "workspaces": [["id": "ws", "name": "canonical", "index": 0, "focused": true]],
            "screens": [],
            "panes": [],
            "tabs": [],
            "terminals": [],
            "browsers": [],
            "agents": [],
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        var canonicalInfo = provider.info
        canonicalInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "canonical", index: 0, focused: true),
        ]
        catalog.replaceCloudState(state, resources: [], info: canonicalInfo)

        var staleInfo = provider.info
        staleInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "old-name", index: 0, focused: false),
            SurfaceRemoteWorkspace(id: "removed", name: "removed", index: 1, focused: false),
        ]
        catalog.updateMachine(staleInfo, from: provider)

        let actualRemoteWorkspaces = catalog.snapshot.machines.first?.remoteWorkspaces
        #expect(actualRemoteWorkspaces == canonicalInfo.remoteWorkspaces)
    }
}

/// Minimal catalog provider for the cursorless-refresh regression. The full
/// SurfaceCatalog fixture is file-private, so keep this moved test self-contained.
@MainActor
private final class CloudTreeCatalogFakeProvider: SurfaceProvider {
    let machine: SurfaceMachineID
    var info: SurfaceMachineInfo

    init(machine: SurfaceMachineID) {
        self.machine = machine
        self.info = SurfaceMachineInfo(
            id: machine,
            name: machine.rawValue,
            status: "running",
            image: nil,
            hasDesktop: false,
            memoryMb: nil,
            diskMb: nil,
            linkState: .connected,
            linkError: nil,
            cpuPercent: nil,
            memoryUsedMb: nil,
            diskUsedMb: nil
        )
    }

    func refresh() async {}

    func materialize(
        _ resource: SurfaceResource,
        at destination: SurfaceDestination,
        focus: Bool
    ) async throws -> SurfaceProjection {
        SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
    }

    func createTerminal(
        command: [String]?,
        cwd: String?,
        name: String?,
        remoteWorkspaceID: String?
    ) async throws -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_new"),
            title: name ?? "shell",
            detail: cwd,
            lifecycle: .launching,
            agent: nil,
            remoteWorkspace: nil,
            port: nil,
            url: nil
        )
    }

    func projectionDidEnd(_ projection: SurfaceProjection) {}
}
