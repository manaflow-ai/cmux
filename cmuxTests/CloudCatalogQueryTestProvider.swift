import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Publishes an already-existing daemon graph on refresh; no network, process,
/// global catalog, or user credential state participates in the fixture.
@MainActor
final class CloudCatalogQueryTestProvider: SurfaceProvider {
    let machine: SurfaceMachineID
    let info: SurfaceMachineInfo
    private let catalog: SurfaceCatalog
    private let state: CloudVMState
    private(set) var forcedRefreshes: [Bool] = []

    init(machine: SurfaceMachineID, catalog: SurfaceCatalog) throws {
        self.machine = machine
        self.catalog = catalog
        info = SurfaceMachineInfo(
            id: machine, name: machine.rawValue, status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        )
        state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "daemon-fixture", "revision": "1"],
            "workspaces": [["id": "ws-1", "name": "workspace-1", "focused": true]],
            "screens": [["id": "screen-1", "workspace_id": "ws-1"]],
            "panes": [["id": "pane-1", "screen_id": "screen-1"]],
            "tabs": [[
                "id": "tab-1", "pane_id": "pane-1", "content_kind": "terminal",
                "content_id": "term-seeded", "focused": true
            ]],
            "terminals": [[
                "id": "term-seeded", "title": "terminal", "running": true,
                "lifecycle": "running", "tab_ids": ["tab-1"]
            ]],
            "browsers": [],
            "agents": []
        ], machine: machine))
    }

    func refresh() async { await refresh(force: false) }

    func refresh(force: Bool) async {
        forcedRefreshes.append(force)
        catalog.replaceCloudState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: info)
    }

    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        Issue.record("Reading a catalog must not create or focus a pane")
        throw SurfaceCatalogError.unsupported("fixture materialization")
    }

    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        Issue.record("Reading a catalog must reuse the seeded terminal")
        throw SurfaceCatalogError.unsupported("fixture terminal creation")
    }

    func projectionDidEnd(_ projection: SurfaceProjection) {}
}
