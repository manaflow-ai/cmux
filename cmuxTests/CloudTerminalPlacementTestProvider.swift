import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Holds every create behind a barrier so pending-pane races need no timing guesses.
@MainActor
final class CloudTerminalPlacementTestProvider: SurfaceLayoutTerminalCreating {
    let machine = SurfaceMachineID.cloud("placement-\(UUID().uuidString)")
    let remote = SurfaceRemoteWorkspace(id: "ws-source", name: "source", index: 0, focused: true)
    let release = CloudLinkFirstValue<Bool>()
    private(set) var requestedWorkspaces: [String?] = []
    private(set) var materialized: [SurfaceProjection] = []
    private(set) var layoutSources: [(tabID: String, direction: SurfaceSplitDirection?)] = []
    var returnedWorkspaceID: String?
    var projectedWorkspaceID: String?
    var projectedMachine: SurfaceMachineID?

    var info: SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machine, name: "fixture", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: [remote]
        )
    }

    func resource(key: String, workspace: SurfaceRemoteWorkspace? = nil) -> SurfaceResource {
        let workspace = workspace ?? remote
        return SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key),
            title: "shell", detail: "/remote/project", lifecycle: .running, agent: nil,
            remoteWorkspace: workspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab-\(key)", workspace: workspace)],
            port: nil, url: nil
        )
    }

    func refresh() async {}
    func projectionDidEnd(_ projection: SurfaceProjection) {}

    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        let key = "created-\(requestedWorkspaces.count)"
        requestedWorkspaces.append(remoteWorkspaceID)
        _ = await release.result
        try Task.checkCancellation()
        var workspace = remote
        workspace.id = returnedWorkspaceID ?? remoteWorkspaceID ?? "WRONG-current-workspace"
        let created = resource(key: key, workspace: workspace)
        SurfaceCatalog.shared.upsert(created, from: self)
        return created
    }

    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource {
        layoutSources.append((nearTabID, splitDirection))
        return try await createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: remote.id)
    }

    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        throw SurfaceCatalogError.unsupported("fixture requires a reserved Cloud pane")
    }

    func materialize(
        _ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination,
        focus: Bool, adopting reservation: CloudTerminalPaneReservation?
    ) async throws -> SurfaceProjection {
        let reservation = try #require(reservation)
        var identity = resource.id
        identity.machine = projectedMachine ?? resource.machine
        let projection = SurfaceProjection(
            resource: identity, workspaceID: reservation.workspaceID, panelID: reservation.panelID,
            remoteWorkspaceID: projectedWorkspaceID ?? remoteView?.workspace.id,
            remoteTabID: remoteView?.tabID
        )
        materialized.append(projection)
        return projection
    }
}
