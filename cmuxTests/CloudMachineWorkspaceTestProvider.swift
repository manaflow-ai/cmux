import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Uses the production native-pane factory with a controlled daemon graph.
@MainActor
final class CloudMachineWorkspaceTestProvider: SurfaceProvider {
    let machine: SurfaceMachineID
    var info: SurfaceMachineInfo
    var beforeMaterialization: (() async throws -> Void)?
    private(set) var materializations = 0
    var returnMismatchedPlacement = false

    init(id: String = UUID().uuidString) {
        machine = .cloud(id)
        info = SurfaceMachineInfo(id: machine, name: "brave-sapphire-lobster", status: "running",
            image: nil, hasDesktop: false, memoryMb: nil, diskMb: nil,
            linkState: .connected, linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }

    func install(in catalog: SurfaceCatalog, generation: String = "created") throws {
        let graph = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": generation, "revision": "1"],
            "workspaces": [["id": "ws-first", "name": "workspace-1", "index": 0, "focused": true]],
            "screens": [["id": "screen", "workspace_id": "ws-first"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": [["id": "tab-first", "pane_id": "pane", "content_kind": "terminal", "content_id": "term-first"]],
            "terminals": [["id": "term-first", "title": "terminal", "lifecycle": "running", "cwd": "/home/cmux"]],
            "browsers": [], "agents": []
        ], machine: machine))
        catalog.replaceCloudState(graph, resources: CmuxTuiSnapshotParser.resources(from: graph), info: info)
        catalog.reconcileCloudRemoteState(machine: machine, state: graph)
    }

    func refresh() async {}

    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        try await materialize(resource, remoteView: resource.remoteViews?.first, at: destination, focus: focus)
    }

    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        materializations += 1
        try await beforeMaterialization?()
        try Task.checkCancellation()
        let native = try SurfacePaneFactory.makeCloudManualMirrorPane(
            at: destination, focus: focus, onInput: { _ in }, onResize: { _ in },
            onRuntimeReady: {}, onFocus: {}, attachment: CloudTerminalAttachmentStatus(machineID: machine.rawValue)
        )
        return SurfaceProjection(resource: resource.id, workspaceID: native.workspaceID,
            panelID: native.panelID,
            remoteWorkspaceID: returnMismatchedPlacement ? "moved-workspace" : remoteView?.workspace.id,
            remoteTabID: remoteView?.tabID)
    }

    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        Issue.record("Machine opening must preserve its seeded terminal")
        throw CloudDiagnosticFailure.placement
    }

    func projectionDidEnd(_ projection: SurfaceProjection) {}
}
