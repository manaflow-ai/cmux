import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudWorkspaceCreationSidebarProvider: SurfaceProvider {
    let machine = SurfaceMachineID.cloud("create-fixture-\(UUID().uuidString)")
    var info: SurfaceMachineInfo
    unowned let catalog: SurfaceCatalog
    var beforeRefresh: (@MainActor () throws -> Void)?
    var terminalCreates = 0
    let remote = SurfaceRemoteWorkspace(id: "ws_receipt", name: "Project", index: 0, focused: true)

    init(catalog: SurfaceCatalog) {
        self.catalog = catalog
        info = SurfaceMachineInfo(id: machine, name: "bright-teal-otter", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }

    var terminal: SurfaceResource {
        SurfaceResource(id: .init(machine: machine, kind: .terminal, key: "term_receipt"), title: "shell",
            detail: nil, lifecycle: .launching, agent: nil, remoteWorkspace: remote,
            remoteViews: [.init(tabID: "tab_receipt", workspace: remote)], port: nil, url: nil)
    }

    func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace {
        info.remoteWorkspaces = [remote]
        catalog.updateMachine(info, from: self)
        catalog.upsert(terminal, from: self)
        return remote
    }

    func refresh() async {
        do { try beforeRefresh?() } catch { Issue.record(error) }
    }

    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        terminalCreates += 1
        return terminal
    }

    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        let pane = try SurfacePaneFactory.makeTerminalPane(initialCommand: nil, workingDirectory: nil, at: destination, focus: focus)
        return SurfaceProjection(resource: resource.id, workspaceID: pane.workspaceID, panelID: pane.panelID,
                                 remoteWorkspaceID: remote.id, remoteTabID: "tab_receipt")
    }

    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination,
                     focus: Bool, adopting reservation: CloudTerminalPaneReservation?) async throws -> SurfaceProjection {
        guard let reservation else { return try await materialize(resource, at: destination, focus: focus) }
        return SurfaceProjection(resource: resource.id, workspaceID: reservation.workspaceID, panelID: reservation.panelID,
                                 remoteWorkspaceID: remote.id, remoteTabID: "tab_receipt")
    }

    func projectionDidEnd(_ projection: SurfaceProjection) {}
}
