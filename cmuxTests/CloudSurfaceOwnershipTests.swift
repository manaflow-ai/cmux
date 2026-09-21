import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud surface ownership", .serialized)
struct CloudSurfaceOwnershipTests {
    private let machine = SurfaceMachineID.cloud("ownership-b")

    @Test("Cloud pane hover rejects local and foreign resources", arguments: SurfaceResourceKind.allCases)
    func rejectsForeignResourceHover(kind: SurfaceResourceKind) throws {
        let workspace = cloudWorkspace()
        defer { workspace.teardownAllPanels() }
        let transfer = PaneDragTransfer(
            tabId: UUID(), sourcePaneId: UUID(),
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )
        for source in [SurfaceMachineID.local, .cloud("ownership-a")] {
            let group = SurfaceResourceGroup(single: resource(source, kind: kind))
            #expect(!workspace.canPerformPortalPaneDrop(transfer, source: .surfaceResources(group)))
        }
        let sameMachine = SurfaceResourceGroup(single: resource(machine, kind: kind))
        #expect(workspace.canPerformPortalPaneDrop(transfer, source: .surfaceResources(sameMachine)))
    }

    @Test("Rejected resource drops do not dispatch or alter layout", arguments: SurfaceResourceKind.allCases)
    func rejectsForeignResourceDrop(kind: SurfaceResourceKind) throws {
        let workspace = cloudWorkspace()
        defer { workspace.teardownAllPanels() }
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let originalPanels = Set(workspace.panels.keys)
        let originalPanes = workspace.bonsplitController.allPaneIds
        let catalog = SurfaceCatalog()
        for source in [SurfaceMachineID.local, .cloud("ownership-a")] {
            let group = SurfaceResourceGroup(single: resource(source, kind: kind))
            #expect(!workspace.handleSurfaceResourceDrop(
                group: group,
                destination: .split(targetPane: pane, orientation: .horizontal, insertFirst: false),
                catalog: catalog
            ))
            #expect(Set(workspace.panels.keys) == originalPanels)
            #expect(workspace.bonsplitController.allPaneIds == originalPanes)
            #expect(catalog.snapshot.projections.isEmpty)
        }
    }

    @Test("Catalog rejects ownership before materializing or focusing", arguments: SurfaceResourceKind.allCases)
    func catalogRejectsForeignResources(kind: SurfaceResourceKind) async throws {
        let workspace = cloudWorkspace()
        defer { workspace.teardownAllPanels() }
        let catalog = catalog(for: workspace)
        var materializations = 0
        var focuses = 0
        catalog.focusProjection = { _ in focuses += 1 }
        for source in [SurfaceMachineID.local, .cloud("ownership-a")] {
            let provider = CloudPlacementTestProvider(machine: source)
            provider.beforeMaterialization = { materializations += 1 }
            catalog.register(provider)
            let item = resource(source, kind: kind)
            catalog.upsert(item)
            do {
                _ = try await catalog.project(item.id, into: .workspace(id: workspace.id, placement: .split))
                Issue.record("A foreign resource was projected into a Cloud workspace")
            } catch {}
        }
        #expect(materializations == 0)
        #expect(focuses == 0)
        #expect(catalog.snapshot.projections.isEmpty)
    }

    @Test("One foreign group member rejects the entire drop before any projection")
    func mixedGroupIsAtomic() async throws {
        let workspace = cloudWorkspace()
        defer { workspace.teardownAllPanels() }
        let catalog = catalog(for: workspace)
        var materializations = 0
        for source in [machine, .local] {
            let provider = CloudPlacementTestProvider(machine: source)
            provider.beforeMaterialization = { materializations += 1 }
            catalog.register(provider)
            catalog.upsert(resource(source, kind: .terminal))
        }
        let group = SurfaceResourceGroup(title: "same title", resources: [
            resource(machine, kind: .terminal).id, resource(.local, kind: .terminal).id
        ])
        do {
            _ = try await catalog.projectGroup(
                group, into: .workspace(id: workspace.id, placement: .tab), focus: false,
                paneLookup: { _, _ in nil }
            )
            Issue.record("A mixed group must be rejected as a whole")
        } catch {}
        #expect(materializations == 0)
        #expect(catalog.snapshot.projections.isEmpty)
    }

    @Test("Same-machine resources and local workspace projections retain their behavior", arguments: SurfaceResourceKind.allCases)
    func acceptedResources(kind: SurfaceResourceKind) async throws {
        for isCloud in [true, false] {
            let workspace = isCloud ? cloudWorkspace() : Workspace()
            defer { workspace.teardownAllPanels() }
            let catalog = catalog(for: workspace)
            let source: SurfaceMachineID = isCloud ? machine : .local
            let provider = CloudPlacementTestProvider(machine: source)
            catalog.register(provider)
            let item = resource(source, kind: kind)
            catalog.upsert(item)
            let result = try await catalog.project(
                item.id, into: .workspace(id: workspace.id, placement: .tab), focus: false
            )
            #expect(result.projection.resource == item.id)
            #expect(result.projection.workspaceID == workspace.id)
            #expect(catalog.snapshot.projections == [result.projection])
        }
    }

    @Test("Sidebar and direct moves reject before detaching the source")
    func moveRejectsWithoutMutation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let source = fixture.workspace
            let destination = fixture.manager.addWorkspace(title: "same title", select: false)
            defer { destination.teardownAllPanels() }
            destination.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false)
            let panel = try #require(source.focusedPanelId)
            let tab = try #require(source.surfaceIdFromPanelId(panel))
            let sourcePanels = Set(source.panels.keys)
            let destinationPanels = Set(destination.panels.keys)
            let selected = fixture.manager.selectedTabId
            #expect(!fixture.appDelegate.canMoveBonsplitTab(tabId: tab.uuid, toWorkspace: destination.id))
            #expect(!fixture.appDelegate.moveSurface(
                panelId: panel, toWorkspace: destination.id, focus: false, focusWindow: false
            ))
            #expect(Set(source.panels.keys) == sourcePanels)
            #expect(Set(destination.panels.keys) == destinationPanels)
            #expect(fixture.manager.selectedTabId == selected)
            #expect(source.surfaceIdFromPanelId(panel) == tab)
        }
    }

    private func cloudWorkspace() -> Workspace {
        let workspace = Workspace()
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false)
        return workspace
    }

    private func catalog(for workspace: Workspace) -> SurfaceCatalog {
        SurfaceCatalog(cloudWorkspaceRenameService: CloudWorkspaceRenameService(
            environment: CloudWorkspaceRenameEnvironment(workspace: { id in
                id == workspace.id ? workspace : nil
            })
        ))
    }

    private func resource(_ machine: SurfaceMachineID, kind: SurfaceResourceKind) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: kind, key: "resource"),
            title: "same title", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: nil, port: nil, url: nil
        )
    }
}
