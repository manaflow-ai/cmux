import AppKit
import Bonsplit
import CmuxControlSocket
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudShortcutTestHarness {
    let app: AppDelegate
    let window: NSWindow
    let manager: TabManager
    let workspace: Workspace
    let provider: CloudShortcutTestProvider
    let source: UUID
    let resource: SurfaceResource

    init(projected: Bool = true) throws {
        app = try #require(AppDelegate.shared)
        let windowID = app.createMainWindow()
        manager = try #require(app.tabManagerFor(windowId: windowID))
        window = try #require(NSApp.windows.first { $0.identifier?.rawValue == "cmux.main.\(windowID.uuidString)" })
        workspace = try #require(manager.selectedWorkspace)
        source = try #require(workspace.focusedPanelId)
        provider = CloudShortcutTestProvider()
        let remote = SurfaceRemoteWorkspace(id: "ws-source", name: "source", index: 0, focused: true)
        resource = SurfaceResource(
            id: SurfaceResourceID(machine: provider.machine, kind: .terminal, key: "term-source"),
            title: "shell", detail: "/remote/project", lifecycle: .running, agent: nil,
            remoteWorkspace: remote, remoteViews: [SurfaceRemoteView(tabID: "tab-source", workspace: remote)],
            port: nil, url: nil
        )
        let catalog = SurfaceCatalog.shared
        catalog.register(provider)
        catalog.upsert(resource, from: provider)
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: provider.machine.cloudMachineID!, isBase: false, remoteWorkspaceID: remote.id)
        if projected {
            catalog.record(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: source,
                remoteWorkspaceID: remote.id, remoteTabID: "tab-source"))
        }
    }

    var routing: ControlRoutingSelectors {
        ControlRoutingSelectors(hasWindowIDParam: false, windowID: nil, groupID: nil,
            workspaceID: workspace.id, surfaceID: nil, paneID: nil)
    }

    func tearDown() {
        workspace.cancelAllReservedCloudTerminalPanes()
        workspace.cloudPaneCreationFailureStore.cancelAll()
        SurfaceCatalog.shared.unregister(machine: provider.machine)
        window.performClose(nil)
    }
}
