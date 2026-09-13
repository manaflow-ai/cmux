import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// In-memory daemon transport; graph acceptance and native reconciliation use production owners.
@MainActor
final class CloudNameAuthorityTestProvider: SurfaceAgentNaming {
    let machine: SurfaceMachineID
    let catalog: SurfaceCatalog
    let renameService: CloudWorkspaceRenameService
    let receiver: CmuxTuiSurfaceProvider
    var info: SurfaceMachineInfo
    var graph: CloudVMState
    var writes: [(String, String)] = []
    var beforeRename: (() async throws -> Void)?

    init(machine: SurfaceMachineID, catalog: SurfaceCatalog, renameService: CloudWorkspaceRenameService) throws {
        self.renameService = renameService
        self.machine = machine
        self.catalog = catalog
        info = SurfaceMachineInfo(id: machine, name: machine.rawValue, status: "running", image: nil,
                                  hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
                                  linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
        receiver = CmuxTuiSurfaceProvider(
            summary: VMSummary(id: machine.rawValue, provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil),
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }), catalog: catalog
        )
        graph = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "fixture", "revision": "1"],
            "workspaces": ["a", "b"].map { ["id": $0, "name": "Same workspace"] },
            "screens": ["a", "b"].map { ["id": "screen_" + $0, "workspace_id": $0] },
            "panes": ["a", "b"].map { ["id": "pane_" + $0, "screen_id": "screen_" + $0] },
            "tabs": ["b", "a"].map { id -> [String: Any] in
                ["id": "tab_" + id, "pane_id": "pane_" + id,
                 "content_kind": "terminal", "content_id": "term_a",
                 "extra": ["name_source": "user", "name_revision": "0"]]
            },
            "terminals": ["a", "b"].map { ["id": "term_" + $0, "title": "terminal", "lifecycle": "running"] },
            "browsers": [], "agents": []
        ], machine: machine))
    }

    @discardableResult
    func install(_ state: CloudVMState) -> Bool {
        guard receiver.installSnapshotIfNewer(state) else { return false }
        graph = state
        catalog.replaceCloudState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: info)
        renameService.reconcileRemoteState(machine: machine, state: state, catalog: catalog, observation: .current)
        return true
    }

    func renameRemoteWorkspace(id: String, name: String) async throws {
        try await beforeRename?()
        try commit(collection: "workspaces", id: id, name: name)
    }

    func renameRemoteTab(id: String, name: String) async throws {
        try await beforeRename?()
        try commit(collection: "tabs", id: id, name: name)
    }

    func renameAgentTab(context: CloudAgentNameContext, name: String) async throws {
        try await beforeRename?()
        guard CloudAgentNameContext(projection: context.projection, state: graph) == context else {
            throw CancellationError()
        }
        try commit(collection: "tabs", id: try #require(context.projection.remoteTabID), name: name, source: "auto")
    }

    private func commit(collection: String, id: String, name: String, source: String = "user") throws {
        var document = try #require(graph.snapshotObject())
        let revision = try #require(graph.cursor).revision + 1
        document["cursor"] = ["generation": try #require(graph.cursor).generation, "revision": String(revision)]
        var values = try #require(document[collection] as? [[String: Any]])
        let index = try #require(values.firstIndex { $0["id"] as? String == id })
        values[index]["name"] = name.isEmpty ? NSNull() : name as Any
        if collection == "tabs" {
            values[index]["extra"] = ["name_source": source, "name_revision": String(revision)]
        }
        document[collection] = values
        writes.append((id, name))
        #expect(install(try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))))
    }

    func refresh() async { _ = install(graph) }
    func projectionDidEnd(_ projection: SurfaceProjection) {}
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        throw CancellationError()
    }
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        throw CancellationError()
    }
}
