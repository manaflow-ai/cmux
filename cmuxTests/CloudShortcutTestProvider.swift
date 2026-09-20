import Foundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudShortcutTestProvider: SurfaceLayoutTerminalCreating {
    struct Call {
        let number: Int
        let nearTabID: String?
        let remoteWorkspaceID: String?
        let command: [String]?
        let cwd: String?
    }
    let machine = SurfaceMachineID.cloud("shortcut-\(UUID().uuidString)")
    let calls = AsyncStream<Call>.makeStream()
    private(set) var callCount = 0
    private var pending: [Int: CheckedContinuation<SurfaceResource, Error>] = [:]
    var info: SurfaceMachineInfo {
        SurfaceMachineInfo(id: machine, name: "Fixture", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }
    func refresh() async {}
    func currentWorkingDirectory(of resource: SurfaceResource) async -> String? { "/remote/project" }
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        try await create(nearTabID: nil, workspace: remoteWorkspaceID, command: command, cwd: cwd)
    }
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource {
        try await create(nearTabID: nearTabID, workspace: "ws-source", command: nil, cwd: nil)
    }
    private func create(nearTabID: String?, workspace: String?, command: [String]?, cwd: String?) async throws -> SurfaceResource {
        callCount += 1
        let number = callCount
        return try await withCheckedThrowingContinuation { continuation in
            pending[number] = continuation
            calls.continuation.yield(Call(number: number, nearTabID: nearTabID,
                remoteWorkspaceID: workspace, command: command, cwd: cwd))
        }
    }
    func succeed(_ number: Int) {
        let remote = SurfaceRemoteWorkspace(id: "ws-source", name: "source", index: 0, focused: true)
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term-created-\(number)"),
            title: "shell", detail: "/remote/project", lifecycle: .running, agent: nil,
            remoteWorkspace: remote, remoteViews: [SurfaceRemoteView(tabID: "tab-created-\(number)", workspace: remote)],
            port: nil, url: nil)
        SurfaceCatalog.shared.upsert(resource, from: self)
        pending.removeValue(forKey: number)?.resume(returning: resource)
    }
    func fail(_ number: Int, error: Error = CloudDiagnosticFailure.network) { pending.removeValue(forKey: number)?.resume(throwing: error) }
    func stop() {
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
        calls.continuation.finish()
    }
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        throw CloudDiagnosticFailure.network
    }
    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination,
                     focus: Bool, adopting reservation: CloudTerminalPaneReservation?) async throws -> SurfaceProjection {
        guard let reservation else { throw CloudDiagnosticFailure.response }
        return SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: reservation.panelID,
            remoteWorkspaceID: resource.remoteWorkspace?.id, remoteTabID: resource.remoteViews?.first?.tabID)
    }
    func projectionDidEnd(_ projection: SurfaceProjection) {}
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool { true }
}
