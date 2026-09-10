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
    var events: [String] = []
    var beforeMutation: (() async throws -> Void)?
    var refreshCount = 0
    var moveCursor: CloudVMCursor?

    init(machine: SurfaceMachineID) {
        self.machine = machine
        info = SurfaceMachineInfo(id: machine, name: machine.rawValue, status: "running", image: nil, hasDesktop: true, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }

    func refresh() async { refreshCount += 1 }
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
    }
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        throw SurfaceCatalogError.unsupported("createTerminal")
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
        return SurfaceRemotePlacement(workspaceID: remoteWorkspaceID, tabID: "tab_projected")
    }
    func closeRemoteTab(id: String, inRemoteWorkspace remoteWorkspaceID: String) async throws {
        events.append("close:" + id)
        try await beforeMutation?()
        closedTabs.append(id)
    }
}
