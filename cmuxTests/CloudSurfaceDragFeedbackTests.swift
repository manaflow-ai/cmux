import CmuxCloud
import AppKit
import Bonsplit
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class CountingCloudDragDestination: NSView {
    var enteredCount = 0
    var updatedCount = 0
    var exitedCount = 0

    /// Records the first native callback and accepts the drag.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        enteredCount += 1
        return .move
    }

    /// Records updates forwarded to the same destination.
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updatedCount += 1
        return .move
    }

    /// Records an unexpected destination transition.
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        exitedCount += 1
    }
}

@MainActor
private final class ChurningCloudDragRootView: NSView {
    var nextHitTestResult: NSView?

    /// Returns one injected portal hit before restoring normal hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let nextHitTestResult {
            self.nextHitTestResult = nil
            return nextHitTestResult
        }
        return super.hitTest(point)
    }
}

@MainActor
@Suite("Cloud drag validation and feedback", .serialized)
struct CloudSurfaceDragFeedbackTests {
    @Test("Cloud pane forwarding stays stable while the pointer remains in one pane")
    /// Keeps the original pane destination through a transient portal hit-test result.
    func destinationStaysValidDuringPortalHitTestChurn() throws {
        let fixture = try CloudSurfaceDragFixture(kind: .display)
        defer { fixture.finish() }
        fixture.workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "a", isBase: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        let root = ChurningCloudDragRootView(frame: window.contentLayoutRect)
        let destination = CountingCloudDragDestination(frame: NSRect(x: 20, y: 20, width: 120, height: 120))
        destination.registerForDraggedTypes([DragOverlayRoutingPolicy.bonsplitTabTransferType])
        root.addSubview(destination)
        let portalHost = NSView(frame: root.bounds)
        root.addSubview(portalHost, positioned: .below, relativeTo: destination)
        let gate = CloudSurfaceDropGateView(frame: root.bounds, sourceResolver: fixture.resolver)
        gate.workspace = fixture.workspace
        gate.isActive = true
        root.addSubview(gate)
        window.contentView = root
        window.orderFront(nil)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cloud-drag-stability-\(UUID())"))
        #expect(fixture.registration.write(to: pasteboard))
        let sender = CloudSidebarDraggingInfo(source: NSOutlineView(), pasteboard: pasteboard, location: NSPoint(x: 80, y: 80))

        #expect(gate.draggingEntered(sender) == .move)
        root.nextHitTestResult = portalHost
        #expect(gate.draggingUpdated(sender) == .move)
        #expect(destination.enteredCount == 1)
        #expect(destination.updatedCount == 1)
        #expect(destination.exitedCount == 0)
    }

    @Test("The pure rule rejects unknown/local/foreign owners and preserves local destinations")
    func policy() {
        let policy = SurfaceOwnershipPolicy(cloudMachine: .cloud("b"))
        for owner in [nil, SurfaceMachineID.local, .cloud("a")] {
            #expect(policy.rejection(for: owner) == .cloudMachineMismatch)
            #expect(SurfaceOwnershipPolicy(cloudMachine: nil).rejection(for: owner) == nil)
        }
        #expect(policy.rejection(for: .cloud("b")) == nil)
        #expect(policy.rejection(for: [SurfaceResourceID]()) == .cloudMachineMismatch)
    }

    @Test("A surface already in the Cloud workspace can be reordered or split within it")
    func ownSurfaceMovesWithinWorkspace() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
        let panelID = try #require(workspace.focusedPanelId)
        let tabID = try #require(workspace.surfaceIdFromPanelId(panelID))
        let paneID = try #require(workspace.paneId(forPanelId: panelID))
        let processID = Int32(ProcessInfo.processInfo.processIdentifier)
        // The workspace's own terminal is local here, the case a Cloud workspace
        // holding a pre-existing local split hits; its own Cloud terminals follow
        // the same path.
        #expect(workspace.machineOwningSurface(panelID) == .local)
        let own = PaneDragTransfer(tabId: tabID.uuid, sourcePaneId: paneID.id, sourceProcessId: processID)
        #expect(workspace.surfaceDropRejection(own, source: .surface) == nil)
        #expect(workspace.canPerformPortalSurfaceDrop(own))

        let foreign = PaneDragTransfer(tabId: UUID(), sourcePaneId: paneID.id, sourceProcessId: processID)
        #expect(workspace.surfaceDropRejection(foreign, source: .surface) == .cloudMachineMismatch)
        let otherProcess = PaneDragTransfer(tabId: tabID.uuid, sourcePaneId: paneID.id, sourceProcessId: processID &+ 1)
        #expect(workspace.surfaceDropRejection(otherProcess, source: .surface) == .cloudMachineMismatch)
    }

    @Test("SwiftUI gate and AppKit pane router agree for every resource kind", arguments: SurfaceResourceKind.allCases)
    func destinationParity(kind: SurfaceResourceKind) throws {
        let fixture = try CloudSurfaceDragFixture(kind: kind)
        defer { fixture.finish() }
        let gate = CloudSurfaceDropGateView(frame: NSRect(x: 0, y: 0, width: 240, height: 240), sourceResolver: fixture.resolver)
        gate.workspace = fixture.workspace
        gate.isActive = true
        for destination in ["b", "a"] {
            fixture.workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: destination, isBase: false)
            let router = fixture.router()
            let result = router.resolve(pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .right)
            if kind == .browser || destination == "a" {
                // Browser surfaces can be moved between Cloud and local
                // workspaces. Terminal and display ownership stays strict.
                guard case .accepted = result else { Issue.record("Same-machine drop was rejected"); return }
                #expect(gate.rejection(for: fixture.pasteboard) == nil)
            } else {
                #expect(result == .rejected)
                #expect(router.rejection == .cloudMachineMismatch)
                #expect(gate.rejection(for: fixture.pasteboard) == router.rejection)
            }
            router.clear()
            #expect(router.rejection == nil)
        }
    }

    @Test("Browser surface transfers are allowed into and out of Cloud workspaces")
    func browserTransfersRemainPortable() throws {
        let cloudWorkspace = Workspace()
        let localWorkspace = Workspace()
        defer {
            cloudWorkspace.teardownAllPanels()
            localWorkspace.teardownAllPanels()
        }
        cloudWorkspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "cloud", isBase: false)
        let transfer = PaneDragTransfer(tabId: UUID(), sourcePaneId: UUID(), sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier))
        let browserGroup = SurfaceResourceGroup(title: "Browser", resources: [SurfaceResourceID(machine: .local, kind: .browser, key: "browser")])
        #expect(cloudWorkspace.surfaceDropRejection(transfer, source: .surfaceResources(browserGroup)) == nil)
        let cloudBrowserGroup = SurfaceResourceGroup(title: "Browser", resources: [SurfaceResourceID(machine: .cloud("cloud"), kind: .browser, key: "browser")])
        #expect(localWorkspace.surfaceDropRejection(transfer, source: .surfaceResources(cloudBrowserGroup)) == nil)
        let mixedTerminalGroup = SurfaceResourceGroup(title: "mixed", resources: [
            SurfaceResourceID(machine: .local, kind: .browser, key: "browser"),
            SurfaceResourceID(machine: .local, kind: .terminal, key: "terminal")
        ])
        #expect(cloudWorkspace.surfaceDropRejection(transfer, source: .surfaceResources(mixedTerminalGroup)) == .cloudMachineMismatch)
        let mixedDisplayGroup = SurfaceResourceGroup(title: "mixed", resources: [
            SurfaceResourceID(machine: .local, kind: .browser, key: "browser"),
            SurfaceResourceID(machine: .local, kind: .display, key: "display")
        ])
        #expect(cloudWorkspace.surfaceDropRejection(transfer, source: .surfaceResources(mixedDisplayGroup)) == .cloudMachineMismatch)
    }

    @Test("Rebinding after hover is rejected before mutation", arguments: [SurfaceResourceKind.terminal, .display])
    func destinationChangesBeforeDrop(kind: SurfaceResourceKind) throws {
        let fixture = try CloudSurfaceDragFixture(kind: kind)
        defer { fixture.finish() }
        fixture.workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "a", isBase: false)
        let router = fixture.router()
        guard case .accepted(let plan) = router.resolve(
            pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .right
        ) else { Issue.record("Same-machine hover should be accepted"); return }
        let panels = Set(fixture.workspace.panels.keys)
        let panes = fixture.workspace.bonsplitController.allPaneIds
        fixture.workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
        #expect(!router.perform(plan, pasteboard: fixture.pasteboard))
        #expect(Set(fixture.workspace.panels.keys) == panels)
        #expect(fixture.workspace.bonsplitController.allPaneIds == panes)
        #expect(router.rejection == nil)
        #expect(!router.perform(plan, pasteboard: fixture.pasteboard))
    }

    @Test("A revoked capability cannot execute a previously accepted plan")
    func staleDragCannotPerform() throws {
        let fixture = try CloudSurfaceDragFixture(kind: .browser)
        defer { fixture.finish() }
        fixture.workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "a", isBase: false)
        let router = fixture.router()
        guard case .accepted(let plan) = router.resolve(
            pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .center
        ) else { Issue.record("Same-machine hover should be accepted"); return }
        fixture.registry.end(fixture.registration)
        #expect(!router.perform(plan, pasteboard: fixture.pasteboard))
        #expect(router.resolve(pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .right) == .rejected)
        router.clear()
    }

    @Test("Warning is red, wrapped, accessible, and cleared on cancel or completion")
    func warningLifecycle() throws {
        let fixture = try CloudSurfaceDragFixture(kind: .display)
        defer { fixture.finish() }
        let view = CloudSurfaceDropGateView(frame: NSRect(x: 0, y: 0, width: 240, height: 240), sourceResolver: fixture.resolver)
        view.workspace = fixture.workspace
        view.isActive = true
        let sender = CloudSidebarDraggingInfo(source: NSOutlineView(), pasteboard: fixture.pasteboard, location: .zero)
        let expected = "Cloud workspaces can only hold terminals and displays from their own Cloud machine. Browser tabs can move freely. Open a local workspace to move other splits there."
        #expect(SurfaceTransferRejection.cloudMachineMismatch.message == expected)
        #expect(view.draggingEntered(sender).isEmpty)
        #expect(view.feedback.rejection == .cloudMachineMismatch)
        #expect(!view.feedback.badge.isHidden)
        #expect(view.feedback.badge.accessibilityLabel() == expected)
        #expect(view.feedback.badge.frame.width <= view.bounds.width)
        #expect(view.feedback.badge.frame.height > 26)
        let label = try #require(view.feedback.badge.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(label.textColor == .systemRed)
        #expect(label.maximumNumberOfLines == 0)
        #expect(!view.acceptsFirstResponder)
        #expect(!view.prepareForDragOperation(sender))
        view.draggingExited(sender)
        #expect(view.feedback.rejection == nil)
        #expect(view.feedback.badge.isHidden)
        #expect(view.feedback.badge.superview == nil)
        #expect(view.draggingEntered(sender).isEmpty)
        #expect(!view.performDragOperation(sender))
        #expect(view.feedback.rejection == nil)
        #expect(view.feedback.badge.isHidden)
        // Rejection leaves the native source in charge of completing its lease.
        #expect(fixture.registry.resolve(from: fixture.pasteboard) != nil)
        view.draggingEnded(sender)
        view.isActive = false
        #expect(view.rejection(for: fixture.pasteboard) == nil)
    }

    @Test("Legacy JSON cannot bypass the live capability registry")
    func legacyPayloadIsRejected() throws {
        let fixture = try CloudSurfaceDragFixture(kind: .terminal)
        defer { fixture.finish() }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("{\"tab\":{\"id\":\"\(UUID())\"},\"sourcePaneId\":\"\(UUID())\",\"sourceProcessId\":1}", forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
        let router = fixture.router()
        #expect(router.resolve(pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .center) == .rejected)
        #expect(router.rejection == .cloudMachineMismatch)
        router.clear()
    }

    @Test("A foreign Cloud terminal warns over the pane and stays silent over the Cloud tree")
    func cloudTreeFeedback() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { app.tearDown() }
            let fixture = CloudSidebarOrderingFixture()
            defer { fixture.close() }
            fixture.coordinator.apply(nodes: fixture.nodes())
            let outline = try #require(fixture.coordinator.outlineView)
            let target = try #require(CloudTreeNodeBuilder.flattened(fixture.nodes()).first { $0.structureTag == "workspace" })
            let focusedPanelID = try #require(app.workspace.focusedPanelId)
            let sourcePanel = try #require(app.workspace.panels[focusedPanelID])
            sourcePanel.retainTransferredSurfaceMachine(.cloud("foreign-cloud"))
            #expect(app.workspace.machineOwningSurface(focusedPanelID) == .cloud("foreign-cloud"))
            let tabID = try #require(app.workspace.surfaceIdFromPanelId(focusedPanelID))
            let pane = try #require(app.workspace.bonsplitController.allPaneIds.first)
            let registration = try #require(app.appDelegate.tabDragTransferRegistry.register(TabDragTransfer(
                tab: Tab(id: tabID, title: "Cloud terminal", kind: "terminal"), sourcePaneId: pane
            )))
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("cloud-tree-ownership-\(UUID())"))
            #expect(registration.write(to: pasteboard))
            defer { app.appDelegate.tabDragTransferRegistry.end(registration); pasteboard.clearContents() }
            let destination = Workspace()
            defer { destination.teardownAllPanels() }
            destination.cloudVMBinding = WorkspaceCloudVMBinding(vmID: fixture.machine.rawValue, isBase: false)
            let gate = CloudSurfaceDropGateView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
            gate.workspace = destination
            gate.isActive = true
            let sourcePanels = Set(app.workspace.panels.keys)
            let destinationPanels = Set(destination.panels.keys)
            let destinationPanes = destination.bonsplitController.allPaneIds
            let organization = fixture.catalog.sidebarOrganization.state
            let sender = CloudSidebarDraggingInfo(source: outline, pasteboard: pasteboard, location: .zero)
            #expect(gate.draggingEntered(sender).isEmpty)
            #expect(gate.feedback.rejection == .cloudMachineMismatch)
            #expect(gate.feedback.badge.accessibilityLabel() == SurfaceTransferRejection.cloudMachineMismatch.message)
            #expect(gate.feedback.badge.superview === gate)
            gate.draggingExited(sender)
            #expect(gate.feedback.badge.superview == nil)
            #expect(fixture.coordinator.outlineView(outline, validateDrop: sender, proposedItem: target,
                                                    proposedChildIndex: NSOutlineViewDropOnItemIndex).isEmpty)
            let host = try #require(fixture.window.contentView?.superview)
            #expect(host.subviews.compactMap { $0 as? FileDropHintBadgeView }.isEmpty)
            #expect(!fixture.coordinator.outlineView(outline, acceptDrop: sender, item: target,
                                                     childIndex: NSOutlineViewDropOnItemIndex))
            #expect(host.subviews.compactMap { $0 as? FileDropHintBadgeView }.isEmpty)
            // A rebuilt outline and the old source's delayed completion must
            // not introduce a second presenter or leave a badge on the window.
            let replacement = CloudTreeContainerView(coordinator: fixture.coordinator)
            let replacementOutline = try #require(fixture.coordinator.outlineView)
            #expect(replacementOutline !== outline)
            #expect(fixture.coordinator.outlineView(replacementOutline, validateDrop: sender, proposedItem: target,
                                                    proposedChildIndex: NSOutlineViewDropOnItemIndex).isEmpty)
            outline.draggingEnded(sender)
            #expect(replacementOutline.subviews.compactMap { $0 as? FileDropHintBadgeView }.isEmpty)
            #expect(host.subviews.compactMap { $0 as? FileDropHintBadgeView }.isEmpty)
            #expect(gate.draggingEntered(sender).isEmpty)
            #expect(gate.feedback.rejection == .cloudMachineMismatch)
            #expect(!gate.performDragOperation(sender))
            #expect(gate.feedback.badge.superview == nil)
            #expect(Set(app.workspace.panels.keys) == sourcePanels)
            #expect(Set(destination.panels.keys) == destinationPanels)
            #expect(destination.bonsplitController.allPaneIds == destinationPanes)
            #expect(fixture.catalog.sidebarOrganization.state == organization)
            #expect(fixture.provider.moved.isEmpty && fixture.provider.projected.isEmpty && fixture.provider.closedTabs.isEmpty)
            #expect(app.appDelegate.tabDragTransferRegistry.resolve(from: pasteboard) != nil)
            _ = replacement
        }
    }

    @Test("Pane warnings stay outside the sidebar and onscreen beside short splits", arguments: [false, true])
    func paneWarningPlacement(short: Bool) throws {
        let fixture = try CloudSurfaceDragFixture(kind: .terminal)
        defer { fixture.finish() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        defer { window.contentView = nil }
        let frame = NSRect(x: 0, y: short ? 420 : 0, width: 240, height: short ? 80 : 500)
        let gate = CloudSurfaceDropGateView(frame: frame, sourceResolver: fixture.resolver)
        root.addSubview(gate)
        gate.workspace = fixture.workspace
        gate.isActive = true
        let sender = CloudSidebarDraggingInfo(source: NSOutlineView(), pasteboard: fixture.pasteboard, location: .zero)
        #expect(gate.draggingEntered(sender).isEmpty)
        let host = try #require(gate.feedback.badge.superview)
        #expect(host === window.contentView?.superview)
        let paneBounds = host.convert(gate.bounds, from: gate)
        #expect(gate.feedback.badge.frame.minX >= paneBounds.minX)
        #expect(gate.feedback.badge.frame.maxX <= paneBounds.maxX)
        #expect(host.bounds.contains(gate.feedback.badge.frame))
        if !short { #expect(paneBounds.contains(gate.feedback.badge.frame)) }
        gate.draggingExited(sender)
        #expect(gate.feedback.badge.superview == nil)
        #expect(gate.draggingEntered(sender).isEmpty)
        window.contentView = nil
        #expect(gate.feedback.badge.superview == nil)
        #expect(gate.feedback.rejection == nil)
    }

    @Test("Every pane destination boundary clears its warning", arguments: [
        "exit", "end", "conclude", "prepare", "drop", "inactive", "workspace", "hide", "detach", "empty", "sameVM", "nonTransfer"
    ])
    func paneWarningCleanup(boundary: String) throws {
        let fixture = try CloudSurfaceDragFixture(kind: .terminal)
        defer { fixture.finish() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
        let gate = CloudSurfaceDropGateView(frame: root.bounds, sourceResolver: fixture.resolver)
        root.addSubview(gate)
        gate.workspace = fixture.workspace
        gate.isActive = true
        let sender = CloudSidebarDraggingInfo(source: NSOutlineView(), pasteboard: fixture.pasteboard, location: .zero)
        #expect(gate.draggingEntered(sender).isEmpty)
        #expect(gate.feedback.rejection == .cloudMachineMismatch)
        switch boundary {
        case "exit": gate.draggingExited(sender)
        case "end": gate.draggingEnded(sender)
        case "conclude": gate.concludeDragOperation(sender)
        case "prepare": #expect(!gate.prepareForDragOperation(sender))
        case "drop": #expect(!gate.performDragOperation(sender))
        case "inactive": gate.isActive = false
        case "workspace": gate.workspace = nil
        case "hide": gate.isHidden = true
        case "detach": gate.removeFromSuperview()
        case "empty":
            gate.setFrameSize(.zero)
            #expect(gate.draggingUpdated(sender).isEmpty)
        case "sameVM":
            fixture.workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "a", isBase: false)
            #expect(gate.draggingUpdated(sender).isEmpty)
            #expect(gate.rejection(for: fixture.pasteboard) == nil)
            guard case .accepted = fixture.router().resolve(
                pasteboard: fixture.pasteboard, context: fixture.context, proposedZone: .right
            ) else { Issue.record("Same-VM drops must still reach the pane destination"); return }
        case "nonTransfer":
            fixture.pasteboard.clearContents()
            #expect(gate.draggingUpdated(sender).isEmpty)
        default: Issue.record("Unknown lifecycle boundary")
        }
        #expect(gate.feedback.rejection == nil)
        #expect(gate.feedback.badge.isHidden)
        #expect(gate.feedback.badge.superview == nil)
    }
}
