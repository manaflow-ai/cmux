import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud drag validation and feedback", .serialized)
struct CloudSurfaceDragFeedbackTests {
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
            if destination == "a" {
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

    @Test("Rebinding after hover is rejected before mutation", arguments: SurfaceResourceKind.allCases)
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
        let expected = "Cloud workspaces can only hold terminals, browsers, and displays from their own Cloud machine. Open a local workspace and move the splits there."
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

    @Test("Cloud tree rows reject foreign surfaces with the same warning")
    func cloudTreeFeedback() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { app.tearDown() }
            let fixture = CloudSidebarOrderingFixture()
            defer { fixture.close() }
            fixture.coordinator.apply(nodes: fixture.nodes())
            let outline = try #require(fixture.coordinator.outlineView as? CloudTreeNSOutlineView)
            let target = try #require(CloudTreeNodeBuilder.flattened(fixture.nodes()).first { $0.structureTag == "workspace" })
            let focusedPanelID = try #require(app.workspace.focusedPanelId)
            let tabID = try #require(app.workspace.surfaceIdFromPanelId(focusedPanelID))
            let pane = try #require(app.workspace.bonsplitController.allPaneIds.first)
            let registration = try #require(app.appDelegate.tabDragTransferRegistry.register(TabDragTransfer(
                tab: Tab(id: tabID, title: "local", kind: "terminal"), sourcePaneId: pane
            )))
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("cloud-tree-ownership-\(UUID())"))
            #expect(registration.write(to: pasteboard))
            defer { app.appDelegate.tabDragTransferRegistry.end(registration); pasteboard.clearContents() }
            let sender = CloudSidebarDraggingInfo(source: outline, pasteboard: pasteboard, location: .zero)
            #expect(fixture.coordinator.outlineView(outline, validateDrop: sender, proposedItem: target,
                                                    proposedChildIndex: NSOutlineViewDropOnItemIndex).isEmpty)
            #expect(outline.ownershipFeedback.rejection == .cloudMachineMismatch)
            #expect(!fixture.coordinator.outlineView(outline, acceptDrop: sender, item: target,
                                                     childIndex: NSOutlineViewDropOnItemIndex))
            #expect(outline.ownershipFeedback.rejection == nil)
            #expect(fixture.provider.moved.isEmpty && fixture.provider.projected.isEmpty && fixture.provider.closedTabs.isEmpty)
        }
    }

}
