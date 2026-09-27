import CmuxCloud
import CmuxSurfaceCatalogModel
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
    var beforeMaterialize: (@MainActor (SurfaceResource, CloudTerminalPaneReservation?) async throws -> Void)?
    var beforeCreate: (@MainActor () async throws -> Void)?
    var afterCreateWorkspace: (@MainActor (SurfaceRemoteWorkspace) async throws -> Void)?
    var usesReceipt = false
    var adoptsReservation = true
    var includesStarter = true
    var terminalError: Error?
    var terminalCreates = 0
    var terminalRequests: [UUID] = []
    var refreshes = 0
    var createdWorkspaces: [SurfaceRemoteWorkspace] = []
    var adoptedPanels: [UUID] = []
    var closedTerminalIDs: [SurfaceResourceID] = []
    var closedWorkspaceIDs: [String] = []
    var onRemoteClose: (@MainActor () -> Void)?

    init(catalog: SurfaceCatalog) {
        self.catalog = catalog
        info = SurfaceMachineInfo(id: machine, name: "bright-teal-otter", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }

    func terminal(in workspace: SurfaceRemoteWorkspace) -> SurfaceResource {
        SurfaceResource(id: .init(machine: machine, kind: .terminal, key: "term_" + workspace.id), title: "shell",
            detail: nil, lifecycle: .launching, agent: nil, remoteWorkspace: workspace,
            remoteViews: [.init(tabID: "tab_" + workspace.id, workspace: workspace,
                                screenID: "screen_" + workspace.id, paneID: "pane_" + workspace.id)], port: nil, url: nil)
    }

    func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace {
        try await beforeCreate?()
        let workspace = SurfaceRemoteWorkspace(id: "ws_\(createdWorkspaces.count)", name: name ?? "Project \(createdWorkspaces.count)",
                                               index: createdWorkspaces.count, focused: true)
        createdWorkspaces.append(workspace)
        info.remoteWorkspaces = createdWorkspaces
        catalog.updateMachine(info, from: self)
        if includesStarter { catalog.upsert(terminal(in: workspace), from: self) }
        return workspace
    }

    func createRemoteWorkspaceReceipt(name: String?) async throws -> SurfaceWorkspaceCreationReceipt {
        let workspace = try await createRemoteWorkspace(name: name)
        try await afterCreateWorkspace?(workspace)
        return SurfaceWorkspaceCreationReceipt(workspace: workspace,
            terminal: usesReceipt && includesStarter ? terminal(in: workspace) : nil,
            cursor: usesReceipt ? .init(generation: "creation", revision: 10) : nil)
    }

    func refresh() async {
        refreshes += 1
        do { try beforeRefresh?() } catch { Issue.record(error) }
    }

    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        terminalCreates += 1
        if let terminalError { throw terminalError }
        let workspace = try #require(createdWorkspaces.first { $0.id == remoteWorkspaceID })
        let resource = terminal(in: workspace)
        catalog.upsert(resource, from: self)
        return resource
    }

    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?, request: CloudTerminalCreationRequest) async throws -> SurfaceResource {
        terminalRequests.append(request.id)
        return try await createTerminal(command: command, cwd: cwd, name: name, remoteWorkspaceID: remoteWorkspaceID)
    }

    func closeTerminal(_ id: SurfaceResourceID) async throws {
        closedTerminalIDs.append(id)
        onRemoteClose?()
    }

    func closeRemoteWorkspace(id: String) async throws {
        closedWorkspaceIDs.append(id)
        onRemoteClose?()
    }

    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        let pane = try SurfacePaneFactory.makeCloudManualMirrorPane(
            at: destination, focus: focus, onInput: { _ in }, keyNameResolver: nil,
            onResize: { _ in }, onRuntimeReady: {}, onFocus: {}
        )
        return SurfaceProjection(resource: resource.id, workspaceID: pane.workspaceID, panelID: pane.panelID,
                                 remoteWorkspaceID: resource.remoteWorkspace?.id, remoteTabID: resource.remoteViews?.first?.tabID)
    }

    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination,
                     focus: Bool, adopting reservation: CloudTerminalPaneReservation?) async throws -> SurfaceProjection {
        try await beforeMaterialize?(resource, reservation)
        guard let reservation, adoptsReservation else { return try await materialize(resource, at: destination, focus: focus) }
        adoptedPanels.append(reservation.panelID)
        return SurfaceProjection(resource: resource.id, workspaceID: reservation.workspaceID, panelID: reservation.panelID,
                                 remoteWorkspaceID: resource.remoteWorkspace?.id, remoteTabID: resource.remoteViews?.first?.tabID)
    }

    func publish(revision: Int, includesWorkspaces: Bool = true, generation: String = "creation", includesTerminals: Bool = true, includesTabs: Bool = true, hasCursor: Bool = true) throws {
        let workspaces = includesWorkspaces ? createdWorkspaces : []
        let terminals = includesTerminals ? workspaces : []
        var document: [String: Any] = [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": workspaces.map { ["id": $0.id, "name": $0.name, "index": $0.index] as [String: Any] },
            "screens": workspaces.map { ["id": "screen_" + $0.id, "workspace_id": $0.id] },
            "panes": workspaces.map { ["id": "pane_" + $0.id, "screen_id": "screen_" + $0.id] },
            "tabs": (includesTabs ? terminals : []).map { ["id": "tab_" + $0.id, "pane_id": "pane_" + $0.id,
                                       "content_kind": "terminal", "content_id": "term_" + $0.id] },
            "terminals": terminals.map { ["id": "term_" + $0.id, "lifecycle": "running", "title": "shell"] },
            "browsers": [], "agents": []
        ]
        if !hasCursor { document.removeValue(forKey: "cursor") }
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
        let resources = revision < 10 && generation == "creation"
            ? createdWorkspaces.map { terminal(in: $0) } : CmuxTuiSnapshotParser.resources(from: state)
        catalog.replaceCloudState(state, resources: resources, info: info)
        catalog.reconcileCloudRemoteState(machine: machine, state: state)
    }

    func projectionDidEnd(_ projection: SurfaceProjection) {}
}
