import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudPlacementTestProvider: SurfaceProvider, SurfacePlacementSyncing {
    let machine: SurfaceMachineID
    var info: SurfaceMachineInfo
    var moved: [(tab: String, workspace: String)] = []
    var projected: [(terminal: String, workspace: String)] = []
    var closedTabs: [String] = []
    var renamedTabs: [(id: String, name: String)] = []
    var events: [String] = []
    var beforeMutation: (() async throws -> Void)?
    var beforeMaterialization: (() async throws -> Void)?
    var refreshCount = 0
    var moveCursor: CloudVMCursor?
    var projectCursor: CloudVMCursor?
    var workspaceRenames: [String] = []
    var tabRenames: [String] = []

    init(machine: SurfaceMachineID) {
        self.machine = machine
        info = SurfaceMachineInfo(id: machine, name: machine.rawValue, status: "running", image: nil, hasDesktop: true, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }

    func refresh() async { refreshCount += 1 }
    func install(_ state: CloudVMState, in catalog: SurfaceCatalog) {
        catalog.replaceCloudState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: info)
        catalog.reconcileCloudRemoteState(machine: machine, state: state, observation: .current)
    }
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
    }
    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        try await beforeMaterialization?()
        return SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID(),
                          remoteWorkspaceID: remoteView?.workspace.id, remoteTabID: remoteView?.tabID)
    }
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        throw SurfaceCatalogError.unsupported("createTerminal")
    }
    func renameRemoteWorkspace(id: String, name: String) async throws {
        try await beforeMutation?()
        workspaceRenames.append(name)
    }
    func renameRemoteTab(id: String, name: String) async throws {
        try await beforeMutation?()
        tabRenames.append(name)
        renamedTabs.append((id, name))
    }
    func projectionDidEnd(_ projection: SurfaceProjection) {}
    func moveRemoteTab(id: String, intoRemoteWorkspace remoteWorkspaceID: String) async throws -> SurfaceRemotePlacement {
        events.append("move-start:" + remoteWorkspaceID)
        try await beforeMutation?()
        moved.append((id, remoteWorkspaceID))
        events.append("move-end:" + remoteWorkspaceID)
        return SurfaceRemotePlacement(workspaceID: remoteWorkspaceID, tabID: id, cursor: moveCursor)
    }
    func projectTerminal(_ id: SurfaceResourceID, intoRemoteWorkspace remoteWorkspaceID: String) async throws -> SurfaceRemotePlacement {
        try await beforeMutation?()
        projected.append((id.key, remoteWorkspaceID))
        return SurfaceRemotePlacement(workspaceID: remoteWorkspaceID, tabID: "tab_projected", cursor: projectCursor)
    }
    func closeRemoteTab(id: String, inRemoteWorkspace remoteWorkspaceID: String) async throws {
        events.append("close:" + id)
        try await beforeMutation?()
        closedTabs.append(id)
    }
}
