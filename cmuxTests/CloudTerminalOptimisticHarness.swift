import AppKit
import Bonsplit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Owns an isolated app window and one controllable Cloud provider.
@MainActor
struct CloudTerminalOptimisticHarness {
    let workspace: Workspace
    let window: NSWindow
    let provider: CloudTerminalOptimisticProvider
    let sourcePanelID: UUID
    let sourcePaneID: PaneID

    init() throws {
        let app = try #require(AppDelegate.shared)
        let id = app.createMainWindow()
        window = try #require(NSApp.windows.first { $0.identifier?.rawValue == "cmux.main.\(id.uuidString)" })
        workspace = try #require(app.tabManagerFor(windowId: id)?.selectedWorkspace)
        sourcePanelID = try #require(workspace.focusedPanelId)
        sourcePaneID = try #require(workspace.bonsplitController.focusedPaneId)
        let machine = SurfaceMachineID.cloud("optimistic-\(UUID().uuidString)")
        provider = CloudTerminalOptimisticProvider(machine: machine)
        let catalog = SurfaceCatalog.shared
        catalog.register(provider)
        let remote = SurfaceRemoteWorkspace(id: "ws", name: "fixture", index: 0, focused: true)
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "source"),
            title: "source", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: remote,
            remoteViews: [SurfaceRemoteView(tabID: "source-tab", workspace: remote)],
            port: nil, url: nil
        )
        catalog.upsert(resource, from: provider)
        catalog.record(SurfaceProjection(
            resource: resource.id, workspaceID: workspace.id, panelID: sourcePanelID,
            remoteWorkspaceID: "ws", remoteTabID: "source-tab"
        ))
    }
    var pending: [CloudTerminalPaneReservation] {
        Array(workspace.cloudPendingCreations.values)
    }
    func shortcut(_ key: String, focus: Bool = true) throws {
        let outcome: TerminalPanelCreationOutcome
        if key == "t" {
            outcome = workspace.newTerminalSurfaceOutcome(
                inPane: try #require(workspace.bonsplitController.focusedPaneId), focus: focus
            )
        } else {
            outcome = workspace.newTerminalSplitOutcome(
                from: try #require(workspace.focusedPanelId),
                orientation: key == "d" ? .horizontal : .vertical, focus: focus
            )
        }
        guard case .routedToRemote = outcome else {
            Issue.record("Cloud shortcut unexpectedly fell through to local creation")
            return
        }
    }
    func close() {
        provider.cancelRequests()
        window.performClose(nil)
        SurfaceCatalog.shared.unregister(machine: provider.machine)
    }
    func shortcutAction(_ key: String) throws {
        let app = try #require(AppDelegate.shared)
        if key == "t" {
            let manager = try #require(app.tabManagerFor(tabId: workspace.id))
            manager.newSurface()
        } else {
            _ = app.performSplitShortcut(direction: key == "d" ? .right : .down, preferredWindow: window)
        }
    }
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }
}
