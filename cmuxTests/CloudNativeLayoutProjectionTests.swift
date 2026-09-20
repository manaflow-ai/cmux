import CmuxCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Native Cloud layout projection preserves panels and focus")
struct CloudNativeLayoutProjectionTests {
    @Test func deviceLayoutWritesAreScopedAndRejectStaleRevisions() throws {
        let workspaceID = UUID()
        let a = UUID().uuidString
        let b = UUID().uuidString
        var layout = DeviceWorkspaceLayoutNode.pane(id: "pane", surfaceIDs: [a, b], selectedSurfaceID: a)
        var writes = 0
        let host = DeviceWorkspaceLayoutHost(
            capture: { $0 == workspaceID ? layout : nil },
            apply: { id, next in
                #expect(id == workspaceID)
                writes += 1
                layout = next
            },
            createTerminal: { _, _, _ in nil },
            publish: { _ in },
            notificationCenter: NotificationCenter()
        )
        let initial = try #require(host.snapshot(for: workspaceID))
        let next = DeviceWorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.35,
            first: .pane(id: "local-a", surfaceIDs: [a], selectedSurfaceID: a),
            second: .pane(id: "local-b", surfaceIDs: [b], selectedSurfaceID: b))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(next))
        let params: [String: Any] = ["workspace_id": workspaceID.uuidString,
            "request_id": "move-1", "base_revision": initial.revision, "layout": encoded]
        let request = MobileHostRPCRequest(id: "edit", method: "device.workspace.layout.apply", params: params, auth: nil)
        guard case .ok = host.handle(request) else { Issue.record("Expected accepted layout"); return }
        #expect(layout.hasSameArrangement(as: next))
        #expect(writes == 1)
        guard case .ok = host.handle(request) else { Issue.record("Expected idempotent receipt"); return }
        #expect(writes == 1)
        var stale = params
        stale["request_id"] = "move-2"
        guard case .failure(let error) = host.handle(.init(id: nil, method: request.method, params: stale, auth: nil)) else {
            Issue.record("A stale edit must be rejected"); return
        }
        #expect(error.code == "layout_conflict")
        stale["base_revision"] = try #require(host.snapshot(for: workspaceID)).revision
        stale["layout"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            DeviceWorkspaceLayoutNode.pane(id: "foreign", surfaceIDs: [UUID().uuidString], selectedSurfaceID: nil)))
        guard case .failure = host.handle(.init(id: nil, method: request.method, params: stale, auth: nil)) else {
            Issue.record("A layout must not borrow terminals from another workspace"); return
        }
        #expect(writes == 1)
    }

    @Test func deviceNamesFollowTheCatalogWithoutCreatingACloudBinding() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let service = CloudWorkspaceRenameService(environment: .init(
            workspace: { $0 == workspace.id ? workspace : nil },
            tabManager: { $0 == workspace.id ? manager : nil }, workspaces: { [workspace] }
        ))
        let catalog = SurfaceCatalog(cloudWorkspaceRenameService: service)
        let machine = SurfaceMachineID.device(SurfaceDeviceInstanceID(deviceID: UUID().uuidString, tag: "default"))
        catalog.register(CloudPlacementTestProvider(machine: machine))
        let remote = SurfaceRemoteWorkspace(id: "source-workspace", name: "Source project", index: 0, focused: true)
        var resource = SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: "terminal"),
            title: "Build logs", detail: "/remote/project", lifecycle: .running, agent: nil, remoteWorkspace: remote,
            remoteViews: [SurfaceRemoteView(tabID: "terminal", workspace: remote, name: "Build logs")], port: nil, url: nil)
        catalog.upsert(resource)
        catalog.record(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: panelID,
            remoteWorkspaceID: remote.id, remoteTabID: "terminal"))
        catalog.replaceResources([resource], on: machine)
        #expect(workspace.title == "Source project")
        #expect(workspace.panelTitle(panelId: panelID) == "Build logs")
        #expect(workspace.cloudVMBinding == nil)
        resource.title = "Tests"
        resource.remoteViews?[0].name = "Tests"
        resource.remoteViews?[0].workspace.name = "Renamed project"
        resource.remoteWorkspace?.name = "Renamed project"
        catalog.replaceResources([resource], on: machine)
        #expect(workspace.title == "Renamed project")
        #expect(workspace.panelTitle(panelId: panelID) == "Tests")
        #expect(workspace.cloudVMBinding == nil)
        for panel in workspace.panels.values { panel.close() }
        manager.tabs = []
    }

    @Test func macLayoutRequestReadsOnlyTheRequestedWorkspace() throws {
        let id = UUID()
        let layout = DeviceWorkspaceLayoutNode.pane(id: "pane", surfaceIDs: ["first", "second"], selectedSurfaceID: "second")
        var reads: [UUID] = []
        let rpc = DeviceWorkspaceLayoutRPC(snapshot: { requested in
            reads.append(requested)
            return requested == id ? layout : nil
        })
        let request = MobileHostRPCRequest(id: "layout", method: "device.workspace.layout", params: ["workspace_id": id.uuidString], auth: nil)
        guard case .ok(let payload) = rpc.handle(request) else {
            Issue.record("Expected a Mac layout snapshot"); return
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        #expect(try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: data) ==
            DeviceWorkspaceLayoutSnapshot(workspaceID: id.uuidString, layout: layout))
        #expect(reads == [id])
        #expect(rpc.handle(MobileHostRPCRequest(id: nil, method: "mobile.sync.fetch", params: [:], auth: nil)) == nil)
        #expect(reads == [id], "Mobile sync does not enter the Mac layout handler")
    }

    @Test func deviceLayoutCapturesNativeTabGroupsAndDividers() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        defer { for panel in workspace.panels.values { panel.close() }; manager.tabs = [] }
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let first = try #require(workspace.focusedPanelId)
        var panels = [first]
        for _ in 0..<3 { panels.append(try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)) }
        let machine = SurfaceMachineID.cloud("layout-capture")
        let projections = panels.enumerated().map { index, panel in
            SurfaceProjection(resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "t\(index)"),
                workspaceID: workspace.id, panelID: panel, remoteWorkspaceID: "remote", remoteTabID: "tab\(index)")
        }
        let placements = projections.map {
            SurfaceResourcePlacement(resource: $0.resource, remoteWorkspaceID: $0.remoteWorkspaceID, remoteTabID: $0.remoteTabID)
        }
        workspace.applyCloudWorkspaceLayout(.split(direction: .right, ratio: 0.65,
            first: .leaf(placements: Array(placements[0...1])),
            second: .split(direction: .down, ratio: 0.3,
                first: .leaf(placements: [placements[2]]), second: .leaf(placements: [placements[3]]))), projections: projections)
        workspace.bonsplitController.selectTab(try #require(workspace.surfaceIdFromPanelId(panels[1])))

        let captured = try #require(workspace.deviceWorkspaceLayoutSnapshot())
        guard case .split(let direction, let ratio, let left, let right) = captured,
              case .pane(_, let leftSurfaces, let selected) = left,
              case .split(let nestedDirection, let nestedRatio, let top, let bottom) = right,
              case .pane(_, let topSurfaces, _) = top,
              case .pane(_, let bottomSurfaces, _) = bottom else {
            Issue.record("The Mac layout tree must preserve the native nested splits"); return
        }
        #expect(direction == .horizontal && abs(ratio - 0.65) < 0.001)
        #expect(nestedDirection == .vertical && abs(nestedRatio - 0.3) < 0.001)
        #expect(leftSurfaces == Array(panels[0...1]).map(\.uuidString))
        #expect(selected == panels[1].uuidString)
        #expect(topSurfaces == [panels[2].uuidString])
        #expect(bottomSurfaces == [panels[3].uuidString])
    }

    @Test func topologyReusesPanelsAndPreservesSelectedTerminal() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let first = try #require(workspace.focusedPanelId)
        let second = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
        let third = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
        let machine = SurfaceMachineID.cloud("native-fixture")
        let projections = [first, second, third].enumerated().map { index, panel in
            SurfaceProjection(resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_\(index)"),
                              workspaceID: workspace.id, panelID: panel, remoteWorkspaceID: "remote", remoteTabID: "tab_\(index)")
        }
        let placements = projections.map {
            SurfaceResourcePlacement(resource: $0.resource, remoteWorkspaceID: $0.remoteWorkspaceID, remoteTabID: $0.remoteTabID)
        }
        let secondTab = try #require(workspace.surfaceIdFromPanelId(second))
        workspace.bonsplitController.selectTab(secondTab)
        let originalPanels = Set(workspace.panels.keys)
        let layout = SurfaceProjectionLayout.split(direction: .right, ratio: 0.6,
            first: .leaf(placements: [placements[0]]), second: .split(direction: .down, ratio: 0.4,
                first: .leaf(placements: [placements[1]]), second: .leaf(placements: [placements[2]])))
        workspace.applyCloudWorkspaceLayout(layout, projections: projections)
        #expect(Set(workspace.panels.keys) == originalPanels)
        #expect(workspace.bonsplitController.allPaneIds.count == 3)
        #expect(workspace.bonsplitController.focusedPaneId == workspace.paneId(forPanelId: second))
        let secondPane = try #require(workspace.paneId(forPanelId: second))
        #expect(workspace.bonsplitController.selectedTab(inPane: secondPane)?.id == secondTab)
        let tree = workspace.bonsplitController.treeSnapshot()
        guard case .split(let root) = tree, case .split(let right) = root.second else {
            Issue.record("Expected the daemon split structure"); return
        }
        #expect(root.orientation == "horizontal" && right.orientation == "vertical")
        #expect(abs(root.dividerPosition - 0.6) < 0.001)
        #expect(abs(right.dividerPosition - 0.4) < 0.001)
        workspace.applyCloudWorkspaceLayout(layout, projections: projections)
        #expect(workspace.bonsplitController.treeSnapshot() == tree, "repeated refresh is a geometry no-op")
        workspace.applyCloudWorkspaceLayout(.leaf(placements: Array(placements.reversed())), projections: projections)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        let finalPane = try #require(workspace.bonsplitController.allPaneIds.first)
        #expect(workspace.bonsplitController.tabs(inPane: finalPane).map(\.id) == [third, second, first].compactMap { workspace.surfaceIdFromPanelId($0) })
        #expect(Set(workspace.panels.keys) == originalPanels)
    }
}
