import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudSurfaceDragFixture {
    let workspace = Workspace()
    let registry = TabDragTransferRegistry()
    let registration: TabDragTransferRegistration
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("cloud-ownership-\(UUID())"))
    let context: PaneDropContext
    let resolver: PaneTransferSourceResolver

    init(kind: SurfaceResourceKind) throws {
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
        let panelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: panelID))
        context = PaneDropContext(workspaceId: workspace.id, panelId: panelID, paneId: paneID)
        let transfer = TabDragTransfer(tab: Tab(title: "same name", kind: kind.rawValue), sourcePaneId: PaneID(id: UUID()))
        registration = try #require(registry.register(transfer))
        let registry = registry
        let group = SurfaceResourceGroup(title: "same name", resources: [
            SurfaceResourceID(machine: .cloud("a"), kind: kind, key: "resource")
        ])
        resolver = PaneTransferSourceResolver(
            vaultSessionRegistry: { nil }, tabTransferRegistry: { registry },
            filePreview: { _ in nil },
            surfaceResource: { $0 == transfer.tab.id.uuid ? group : nil },
            surfaceIsLive: { _ in false }
        )
        #expect(registration.write(to: pasteboard))
    }

    func router() -> PaneTransferDropRouter {
        PaneTransferDropRouter(containerResolver: { [workspace] _ in workspace }, sourceResolver: resolver)
    }

    func finish() {
        registry.end(registration)
        pasteboard.clearContents()
        workspace.teardownAllPanels()
    }
}
