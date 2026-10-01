import CmuxCloud
import CmuxSurfaceCatalogModel
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
    let machine: SurfaceMachineID
    let catalog: SurfaceCatalog
    let remote = SurfaceRemoteWorkspace(id: "ws-source", name: "source", index: 0, focused: true)
    let release = CloudLinkFirstValue<Bool>()
    let creationStarted = CloudLinkFirstValue<Bool>()
    let materializationFinished = CloudLinkFirstValue<Bool>()
    private(set) var requestedCommands: [[String]?] = []
    private(set) var closedTerminals: [SurfaceResourceID] = []
    private(set) var requestedWorkspaces: [String?] = []
    private(set) var requestedDirectories: [String?] = []
    private(set) var materialized: [SurfaceProjection] = []
    private(set) var layoutSources: [(tabID: String, direction: SurfaceSplitDirection?)] = []
    var returnedWorkspaceID: String?
    var projectedWorkspaceID: String?
    var projectedMachine: SurfaceMachineID?
    var omitRemoteViews = false
    var contradictoryViewWorkspaceID: String?

    init(machine: SurfaceMachineID = .cloud("placement-\(UUID())"), catalog: SurfaceCatalog? = nil) {
        self.machine = machine
        self.catalog = catalog ?? SurfaceCatalog.shared
    }

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
            remoteWorkspace: machine.isLocal ? nil : workspace,
            remoteViews: machine.isLocal ? nil : [SurfaceRemoteView(tabID: "tab-\(key)", workspace: workspace)],
            port: nil, url: nil
        )
    }

    func currentWorkingDirectory(of resource: SurfaceResource) async -> String? { resource.detail }

    func closeTerminal(_ id: SurfaceResourceID) async throws { closedTerminals.append(id) }
    func refresh() async {}
    func projectionDidEnd(_ projection: SurfaceProjection) {}

    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        let key = "created-\(requestedWorkspaces.count)"
        requestedWorkspaces.append(remoteWorkspaceID)
        requestedDirectories.append(cwd)
        requestedCommands.append(command)
        creationStarted.resolve(true)
        _ = await release.result
        try Task.checkCancellation()
        var workspace = remote
        workspace.id = returnedWorkspaceID ?? remoteWorkspaceID ?? "WRONG-current-workspace"
        var created = resource(key: key, workspace: workspace)
        if omitRemoteViews { created.remoteViews = nil }
        if let contradictoryViewWorkspaceID {
            let other = SurfaceRemoteWorkspace(id: contradictoryViewWorkspaceID, name: "other", index: 1, focused: false)
            created.remoteViews = [SurfaceRemoteView(tabID: "tab-\(key)", workspace: other)]
        }
        catalog.upsert(created, from: self)
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
        var identity = resource.id
        identity.machine = projectedMachine ?? resource.machine
        let projection = SurfaceProjection(
            resource: identity, workspaceID: reservation?.workspaceID ?? destination.workspaceID, panelID: reservation?.panelID ?? UUID(),
            remoteWorkspaceID: projectedWorkspaceID ?? remoteView?.workspace.id,
            remoteTabID: remoteView?.tabID
        )
        materialized.append(projection)
        materializationFinished.resolve(true)
        return projection
    }
}
