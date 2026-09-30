import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Native panes with a controllable attachment boundary and no guest mutations.
@MainActor
final class CloudWorkspaceRowOpenProvider: SurfaceProvider {
    let machine: SurfaceMachineID
    let info: SurfaceMachineInfo
    var gate: CloudLinkFirstValue<Bool>?
    let started = CloudLinkFirstValue<Bool>()
    /// Resolved as the first successful attachment returns to its caller, which
    /// then finishes on the main actor before any waiter resumes.
    let answered = CloudLinkFirstValue<Bool>()
    var materializations = 0
    var failAt: Int?
    var remoteCloses = 0
    /// Answers with this tab instead of the requested one, like a stale daemon reply.
    var answeredTabID: String?
    /// Fails the attachment of this tab only.
    var failTabID: String?
    /// Binds the attachment to the reserved pane, as the Cloud provider does.
    var adoptsTerminalReservations: Bool { true }

    init(machine: SurfaceMachineID) {
        self.machine = machine
        info = SurfaceMachineInfo(id: machine, name: "Fixture", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }

    func refresh() async {}
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        throw CloudDiagnosticFailure.conflict
    }
    func closeRemoteWorkspace(id: String) async throws { remoteCloses += 1 }
    func closeTerminal(_ id: SurfaceResourceID) async throws { remoteCloses += 1 }
    func projectionDidEnd(_ projection: SurfaceProjection) {}
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        try await materialize(resource, remoteView: nil, at: destination, focus: focus, adopting: nil)
    }
    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination,
                     focus: Bool, adopting reservation: CloudTerminalPaneReservation?) async throws -> SurfaceProjection {
        materializations += 1
        started.resolve(true)
        if let gate { _ = await gate.result }
        if materializations == failAt { throw CloudDiagnosticFailure.conflict }
        if let failTabID, remoteView?.tabID == failTabID { throw CloudDiagnosticFailure.conflict }
        let pane: (workspaceID: UUID, panelID: UUID)
        if let reservation {
            pane = (reservation.workspaceID, reservation.panelID)
        } else if resource.kind == .terminal {
            let created = try SurfacePaneFactory.makeCloudManualMirrorPane(at: destination, focus: focus, onInput: { _ in },
                keyNameResolver: nil, onResize: { _ in }, onRuntimeReady: {}, onFocus: {})
            pane = (created.workspaceID, created.panelID)
        } else {
            pane = try SurfacePaneFactory.makeBrowserPane(url: nil, at: destination, focus: focus)
        }
        let view = remoteView ?? resource.remoteViews?.first
        answered.resolve(true)
        return SurfaceProjection(resource: resource.id, workspaceID: pane.workspaceID, panelID: pane.panelID,
            remoteWorkspaceID: view?.workspace.id, remoteTabID: answeredTabID ?? view?.tabID)
    }
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        return false
    }
}
