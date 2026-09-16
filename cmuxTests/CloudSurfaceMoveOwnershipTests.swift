import AppKit
import struct CmuxCore.WorkspaceRemoteConfiguration
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud surface mutation boundaries", .serialized)
struct CloudSurfaceMoveOwnershipTests {
    @Test("Foreign Cloud terminal, browser and display moves leave both workspaces intact", arguments: SurfaceResourceKind.allCases)
    func foreignCloudMove(kind: SurfaceResourceKind) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let source = fixture.workspace
            let target = fixture.manager.addWorkspace(title: "same name", select: false)
            defer { target.teardownAllPanels() }
            target.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
            let sourcePane = try #require(source.bonsplitController.allPaneIds.first)
            let panelID: UUID
            if kind == .terminal {
                panelID = try #require(source.focusedPanelId)
            } else {
                panelID = try #require(source.newBrowserSurface(inPane: sourcePane, url: URL(string: "about:blank"), focus: false)).id
            }
            let resource = resource(machine: "a", kind: kind)
            let catalog = SurfaceCatalog.shared
            catalog.upsert(resource)
            catalog.record(SurfaceProjection(resource: resource.id, workspaceID: source.id, panelID: panelID))
            defer { catalog.endProjections(panelID: panelID, reason: .replaced); catalog.remove(resource.id) }
            let tabID = try #require(source.surfaceIdFromPanelId(panelID))
            let targetPane = try #require(target.bonsplitController.allPaneIds.first)
            let sourcePanels = Set(source.panels.keys)
            let targetPanels = Set(target.panels.keys)
            let projection = catalog.projection(forPanel: panelID)
            #expect(!fixture.appDelegate.canMoveBonsplitTab(tabId: tabID.uuid, toWorkspace: target.id))
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("ownership-portals-\(UUID())"))
            let registration = try #require(fixture.appDelegate.tabDragTransferRegistry.register(TabDragTransfer(
                tab: Tab(id: tabID, title: "same name", kind: kind.rawValue), sourcePaneId: sourcePane
            )))
            #expect(registration.write(to: pasteboard))
            defer { fixture.appDelegate.tabDragTransferRegistry.end(registration); pasteboard.clearContents() }
            let sender = CloudSidebarDraggingInfo(source: NSOutlineView(), pasteboard: pasteboard, location: NSPoint(x: 100, y: 100))
            let context = PaneDropContext(workspaceId: target.id, panelId: try #require(target.focusedPanelId), paneId: targetPane)
            let terminalTarget = PaneDropTargetView(frame: NSRect(x: 0, y: 0, width: 260, height: 220))
            terminalTarget.dropContext = context
            let browserTarget = BrowserPaneDropTargetView(frame: terminalTarget.frame)
            browserTarget.dropContext = context
            for view in [terminalTarget as NSView, browserTarget as NSView] {
                let portal = try #require(view as? any FileDropPaneTarget)
                #expect(portal.fileDropDraggingEntered(sender).isEmpty)
                let badge = try #require(view.subviews.compactMap { $0 as? FileDropHintBadgeView }.first)
                #expect(badge.accessibilityLabel() == SurfaceTransferRejection.cloudMachineMismatch.message)
                #expect(!portal.fileDropPrepareForDragOperation(sender))
                #expect(!portal.fileDropPerformDragOperation(sender))
                portal.fileDropDraggingExited(sender)
                #expect(badge.isHidden)
            }
            let sidebar = SidebarBonsplitTabWorkspaceDropView(frame: terminalTarget.frame)
            sidebar.updateOwnershipFeedback(action: .existingWorkspace(target.id), pasteboard: pasteboard)
            #expect(sidebar.ownershipFeedback.rejection == .cloudMachineMismatch)
            sidebar.draggingExited(sender)
            #expect(sidebar.ownershipFeedback.rejection == nil)
            let request = BonsplitController.ExternalTabDropRequest(
                tabId: tabID, sourcePaneId: sourcePane,
                destination: .split(targetPane: targetPane, orientation: .horizontal, insertFirst: false)
            )
            #expect(target.bonsplitController.onExternalTabDrop?(request) == false)
            let result = TerminalController.shared.v2SurfaceMove(params: [
                "surface_id": panelID.uuidString, "workspace_id": target.id.uuidString, "focus": false
            ])
            guard case .err(let code, let message, _) = result else {
                Issue.record("CLI move must reject the same ownership mismatch")
                return
            }
            #expect(code == "invalid_params")
            #expect(message == SurfaceTransferRejection.cloudMachineMismatch.message)
            #expect(Set(source.panels.keys) == sourcePanels)
            #expect(Set(target.panels.keys) == targetPanels)
            #expect(target.bonsplitController.allPaneIds == [targetPane])
            #expect(source.surfaceIdFromPanelId(panelID) == tabID)
            #expect(catalog.projection(forPanel: panelID) == projection)
        }
    }

    @Test("Another window cannot bypass Cloud ownership")
    func foreignWindowMove() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let otherManager = TabManager(autoWelcomeIfNeeded: false)
            let otherWindow = fixture.appDelegate.registerMainWindowContextForTesting(tabManager: otherManager)
            defer {
                otherManager.tabs.forEach { $0.teardownAllPanels() }
                fixture.appDelegate.unregisterMainWindowContextForTesting(windowId: otherWindow)
            }
            let target = try #require(otherManager.selectedWorkspace)
            target.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
            let panel = try #require(fixture.workspace.focusedPanelId)
            let tab = try #require(fixture.workspace.surfaceIdFromPanelId(panel))
            #expect(!fixture.appDelegate.canMoveBonsplitTab(tabId: tab.uuid, toWorkspace: target.id))
            #expect(!fixture.appDelegate.moveBonsplitTab(tabId: tab.uuid, toWorkspace: target.id, focus: false, focusWindow: false))
            #expect(fixture.workspace.panels[panel] != nil)
            #expect(target.panels[panel] == nil)
        }
    }

    @Test("Dock-to-Cloud rejection preserves the dock and target")
    func dockMove() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let dock = fixture.workspace.requiredDockSplitForTesting
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            let panelID = try #require(dock.newSurface(kind: .terminal, inPane: dockPane, focus: false))
            let tabID = try #require(dock.surfaceId(forPanelId: panelID))
            let target = fixture.manager.addWorkspace(title: "Cloud", select: false)
            defer { target.teardownAllPanels() }
            target.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
            let pane = try #require(target.bonsplitController.allPaneIds.first)
            let panels = Set(target.panels.keys)
            let sourcePanels = Set(dock.panels.keys)
            let transfer = PaneDragTransfer(
                tabId: tabID.uuid, sourcePaneId: dockPane.id,
                sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
            )
            #expect(!target.canPerformPortalPaneDrop(transfer, source: .surface))
            #expect(!fixture.appDelegate.canMoveBonsplitTab(tabId: tabID.uuid, toWorkspace: target.id))
            #expect(!fixture.appDelegate.moveDockSurfaceToWorkspace(
                sourceDock: dock, panelId: panelID, toWorkspace: target.id,
                targetPane: pane, targetIndex: nil, splitTarget: (.horizontal, false),
                focus: false, focusWindow: false
            ))
            #expect(Set(dock.panels.keys) == sourcePanels)
            #expect(Set(target.panels.keys) == panels)
            #expect(dock.surfaceId(forPanelId: panelID) == tabID)
        }
    }

    @Test("Same-machine live moves preserve identity", arguments: SurfaceResourceKind.allCases)
    func sameMachineMove(kind: SurfaceResourceKind) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let source = fixture.workspace
            let target = fixture.manager.addWorkspace(title: "Cloud", select: false)
            defer { target.teardownAllPanels() }
            target.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
            let pane = try #require(source.bonsplitController.allPaneIds.first)
            let panelID: UUID
            if kind == .terminal {
                panelID = try #require(source.newTerminalSurface(inPane: pane, focus: false)).id
            } else {
                panelID = try #require(source.newBrowserSurface(inPane: pane, url: URL(string: "about:blank"), focus: false)).id
            }
            let item = resource(machine: "b", kind: kind)
            let catalog = SurfaceCatalog.shared
            catalog.upsert(item)
            catalog.record(SurfaceProjection(resource: item.id, workspaceID: source.id, panelID: panelID))
            defer { catalog.endProjections(panelID: panelID, reason: .replaced); catalog.remove(item.id) }
            let tabID = try #require(source.surfaceIdFromPanelId(panelID))
            #expect(fixture.appDelegate.canMoveBonsplitTab(tabId: tabID.uuid, toWorkspace: target.id))
            #expect(fixture.appDelegate.moveSurface(panelId: panelID, toWorkspace: target.id, focus: false, focusWindow: false))
            #expect(source.panels[panelID] == nil)
            #expect(target.panels[panelID] != nil)
            #expect(catalog.projection(forPanel: panelID)?.resource == item.id)
        }
    }

    @Test("Pending restored projections retain ownership while offline")
    func offlineOwnership() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let catalog = SurfaceCatalog()
        let id = SurfaceResourceID(machine: .cloud("a"), kind: .display, key: "offline")
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: id)], workspaceID: workspace.id)
        #expect(workspace.machineOwningSurface(panelID, catalog: catalog) == .cloud("a"))
        #expect(SurfaceOwnershipPolicy(cloudMachine: .cloud("b")).rejection(for: catalog.machineOwningPanel(panelID)) == .cloudMachineMismatch)
        #expect(SurfaceOwnershipPolicy(cloudMachine: .cloud("a")).rejection(for: catalog.machineOwningPanel(panelID)) == nil)
    }

    @Test("A Dock sharing the target workspace ID is not a rollback into that workspace")
    func dockOriginCannotBypassFinalAttachGuard() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let workspace = fixture.workspace
            workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
            let dock = workspace.requiredDockSplitForTesting
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            let targetPane = try #require(workspace.bonsplitController.allPaneIds.first)
            let panelID = try #require(dock.newSurface(kind: .terminal, inPane: dockPane, focus: false))
            let targetPanels = Set(workspace.panels.keys)
            let transfer = try #require(dock.detachSurface(panelId: panelID))
            #expect(transfer.sourceWorkspaceId == workspace.id)
            #expect(transfer.origin == .dock(workspace.id))
            #expect(workspace.attachDetachedSurface(transfer, inPane: targetPane, focus: false) == nil)
            #expect(Set(workspace.panels.keys) == targetPanels)
            #expect(dock.attachDetachedSurface(transfer, inPane: dockPane, focus: false) == panelID)
        }
    }

    private func resource(machine: String, kind: SurfaceResourceKind) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: .cloud(machine), kind: kind, key: UUID().uuidString),
            title: "same name", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: nil, port: nil, url: nil
        )
    }

    @Test("Legacy Cloud ownership survives a move through a local workspace")
    func legacyCloudTerminalRoundTrip() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let source = fixture.workspace
            let sourcePane = try #require(source.bonsplitController.allPaneIds.first)
            let panel = try #require(source.newTerminalSurface(inPane: sourcePane, focus: false))
            source.configureRemoteConnection(WorkspaceRemoteConfiguration(
                destination: "fixture.invalid", port: 22, identityFile: nil, sshOptions: [],
                localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
                managedCloudVMID: "legacy-a", terminalStartupCommand: nil, skipDaemonBootstrap: true
            ), autoConnect: false)
            source.trackRemoteTerminalSurface(panel.id)
            let local = fixture.manager.addWorkspace(title: "Local", select: false)
            let foreign = fixture.manager.addWorkspace(title: "Cloud B", select: false)
            foreign.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
            defer { local.teardownAllPanels(); foreign.teardownAllPanels() }
            #expect(source.machineOwningSurface(panel.id) == .cloud("legacy-a"))
            #expect(fixture.appDelegate.moveSurface(panelId: panel.id, toWorkspace: local.id, focus: false, focusWindow: false))
            #expect(local.remoteConfiguration == nil)
            #expect(local.machineOwningSurface(panel.id) == .cloud("legacy-a"))
            #expect(!fixture.appDelegate.moveSurface(panelId: panel.id, toWorkspace: foreign.id, focus: false, focusWindow: false))
            let tab = try #require(local.surfaceIdFromPanelId(panel.id))
            let transfer = PaneDragTransfer(tabId: tab.uuid, sourcePaneId: try #require(local.paneId(forPanelId: panel.id)).id,
                                           sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier))
            let group = SurfaceResourceGroup(title: "Legacy", resources: [LocalSurfaceProvider.resourceID(forTerminalPanel: panel.id)])
            #expect(source.canPerformPortalPaneDrop(transfer, source: .surfaceResources(group)))
            #expect(fixture.appDelegate.moveSurface(panelId: panel.id, toWorkspace: source.id, focus: false, focusWindow: false))
            #expect(source.panels[panel.id] != nil)
            #expect(local.panels[panel.id] == nil)
        }
    }
}
