import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Drives the Cloud tree through the snapshots a create publishes (the receipt's
/// pending row, then the daemon's confirmed graph) in `updateNSView`'s order:
/// nodes first, then the window's creation reveal.
@MainActor
@Suite("Cloud tree reveals a created workspace", .serialized)
struct CloudTreeCreationRevealTests {
    @Test("Focused Cloud workspace changes move the native highlight without stealing later row selections")
    func focusedWorkspaceSelectionFollowsFocusChangesOnly() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let first = UUID(), second = UUID()
        let unprojected = UUID()
        var snapshot = fixture.snapshot()
        snapshot.projections = snapshot.resources.enumerated().map { index, resource in
            let remoteWorkspaceID = "ws_\(index + 1)"
            let localWorkspaceID = index == 0 ? first : second
            return SurfaceProjection(
                resource: resource.id, workspaceID: localWorkspaceID, panelID: UUID(),
                remoteWorkspaceID: remoteWorkspaceID, remoteTabID: "tab_\(remoteWorkspaceID)"
            )
        }
        let makeInputs: (UUID) -> CloudTreeBuildInputs = { focused in
            .init(
                machines: [], snapshot: snapshot,
                localWorkspaces: [
                    .init(id: first, title: "first", isSelected: focused == first),
                    .init(id: second, title: "second", isSelected: focused == second),
                    .init(id: unprojected, title: "unprojected", isSelected: focused == unprojected),
                ], source: .cloud
            )
        }

        fixture.coordinator.update(inputs: makeInputs(first))
        let outline = try #require(fixture.coordinator.outlineView)
        #expect((outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id == fixture.folderID("ws_1"))

        fixture.coordinator.update(inputs: makeInputs(second))
        #expect((outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id == fixture.folderID("ws_2"))

        fixture.coordinator.update(inputs: makeInputs(unprojected))
        #expect(outline.selectedRow == -1)

        let machineCandidate = CloudTreeNodeBuilder.flattened(fixture.coordinator.nodes).first(where: \.isMachineRow)
        let machine = try #require(machineCandidate)
        let machineRow = outline.row(forItem: machine)
        outline.selectRowIndexes(IndexSet(integer: machineRow), byExtendingSelection: false)
        fixture.coordinator.update(inputs: makeInputs(unprojected))
        #expect((outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id == machine.id)
    }

    @Test("The Cloud tree can resolve the focused local workspace to its remote row")
    func resolvesFocusedCloudWorkspaceRow() {
        let machine = SurfaceMachineID.cloud("new-machine")
        let localWorkspaceID = UUID()
        let remoteWorkspace = SurfaceRemoteWorkspace(id: "workspace-1", name: "workspace-1", index: 0, focused: true)
        let node = CloudTreeNode(
            id: CloudTreeNodeBuilder.nodeID(workspace: remoteWorkspace.id, machine: machine),
            kind: .workspace(
                machine: machine, remoteWorkspace, terminalCount: 1, hiddenTabCount: 0,
                openIn: localWorkspaceID
            )
        )

        #expect(
            CloudTreeOutlineView.Coordinator.selectedCloudWorkspaceNodeID(
                in: [node], focusedWorkspaceID: localWorkspaceID
            ) == node.id
        )
    }

    @Test("A focused create selects, expands to and scrolls to its row without taking focus, and holds it once confirmed")
    func focusedCreateRevealsThePendingRowAndHoldsItThroughConfirmation() throws {
        let tree = Tree()
        defer { tree.close() }
        let outline = try tree.outline()
        try tree.click(tree.machineID)
        outline.collapseItem(try tree.node(tree.machineID))
        tree.fixture.window.setContentSize(NSSize(width: 380, height: 80))
        tree.fixture.container.layoutSubtreeIfNeeded()
        outline.scrollRowToVisible(0)
        let viewportHeight = outline.visibleRect.height
        let responder = tree.fixture.window.firstResponder
        let token = UUID()

        tree.render(tree.existing, reveal: .init(token: token))
        #expect(tree.selection == tree.machineID, "No row exists before the daemon's receipt names the workspace")
        tree.render(tree.existing, reveal: tree.received(token))
        #expect(tree.selection == tree.machineID, "The receipt can reach the window before the catalog's row does")
        #expect(!outline.isItemExpanded(try tree.node(tree.machineID)))

        tree.render(tree.pending, reveal: tree.received(token))
        #expect(tree.selection == tree.createdID)
        #expect(tree.fixture.coordinator.selectedNodeID == tree.createdID)
        #expect(outline.isItemExpanded(try tree.node(tree.machineID)))
        let row = outline.row(forItem: try tree.node(tree.createdID))
        #expect(outline.rect(ofRow: row).maxY > viewportHeight, "The new row starts below the initial viewport")
        #expect(outline.visibleRect.contains(outline.rect(ofRow: row)))
        #expect(tree.fixture.window.firstResponder === responder, "Revealing never takes focus from the new terminal")

        let log = SelectionLog(outline: outline)
        defer { log.stop() }
        tree.render(tree.confirmed, reveal: tree.received(token))
        tree.render(tree.confirmed, reveal: tree.received(token))
        #expect(tree.selection == tree.createdID)
        #expect(log.selections.allSatisfy { $0 == nil || $0 == tree.createdID }, "Confirmation must not flicker to another row")
        #expect(tree.fixture.window.firstResponder === responder)
    }

    @Test("An unfocused create leaves the selection where it was", arguments: [false, true])
    func unfocusedCreateDoesNotMoveTheSelection(hasSelection: Bool) throws {
        let tree = Tree()
        defer { tree.close() }
        if hasSelection { try tree.click(tree.fixture.folderID("ws_1")) }
        let before = tree.selection

        tree.render(tree.pending, reveal: nil)
        tree.render(tree.confirmed, reveal: nil)
        #expect(tree.selection == before)
    }

    @Test("A create that fails leaves the prior selection intact", arguments: [false, true])
    func failedCreateLeavesThePriorSelection(hasSelection: Bool) throws {
        let tree = Tree()
        defer { tree.close() }
        if hasSelection { try tree.click(tree.machineID) }
        let before = tree.selection

        // Failed before the receipt: the retained row may still appear, unselected.
        let early = UUID()
        tree.render(tree.existing, reveal: .init(token: early))
        tree.render(tree.existing, reveal: .init(token: early, isWithdrawn: true))
        tree.render(tree.pending, reveal: .init(token: early, isWithdrawn: true))
        #expect(tree.selection == before)

        // Failed, cancelled or rejected after the row was revealed: put the
        // selection back while the user has not moved it.
        let late = UUID()
        tree.render(tree.existing, reveal: .init(token: late))
        tree.render(tree.pending, reveal: tree.received(late))
        #expect(tree.selection == tree.createdID)
        tree.render(tree.pending, reveal: tree.received(late, withdrawn: true))
        #expect(tree.selection == before)
        #expect(tree.fixture.coordinator.selectedNodeID == before)
        tree.render(tree.existing, reveal: tree.received(late, withdrawn: true))
        #expect(tree.selection == before)
    }

    @Test("A withdrawn create scrolls the restored row back into view")
    func withdrawnCreateScrollsTheRestoredRowIntoView() throws {
        let tree = Tree()
        defer { tree.close() }
        let outline = try tree.outline()
        try tree.click(tree.machineID)
        outline.collapseItem(try tree.node(tree.machineID))
        tree.fixture.window.setContentSize(NSSize(width: 380, height: 80))
        tree.fixture.container.layoutSubtreeIfNeeded()
        outline.scrollRowToVisible(0)
        let token = UUID()
        tree.render(tree.existing, reveal: .init(token: token))
        tree.render(tree.pending, reveal: tree.received(token))
        #expect(tree.selection == tree.createdID)
        // The user keeps scrolling while the new workspace is shown.
        outline.scrollRowToVisible(outline.numberOfRows - 1)
        let machineRow = outline.row(forItem: try tree.node(tree.machineID))
        try #require(!outline.visibleRect.contains(outline.rect(ofRow: machineRow)))

        tree.render(tree.pending, reveal: tree.received(token, withdrawn: true))
        #expect(tree.selection == tree.machineID)
        #expect(outline.visibleRect.contains(outline.rect(ofRow: machineRow)), "The restored row is brought back into view")
    }

    @Test("A user click during an in-flight create wins", arguments: [false, true])
    func userClickDuringCreateWins(afterReveal: Bool) throws {
        let tree = Tree()
        defer { tree.close() }
        try tree.click(tree.machineID)
        let token = UUID()
        tree.render(tree.existing, reveal: .init(token: token))
        let clicked = tree.fixture.folderID(afterReveal ? "ws_2" : "ws_1")
        if afterReveal {
            tree.render(tree.pending, reveal: tree.received(token))
            #expect(tree.selection == tree.createdID)
        }
        try tree.click(clicked)

        tree.render(tree.pending, reveal: tree.received(token))
        tree.render(tree.confirmed, reveal: tree.received(token))
        #expect(tree.selection == clicked)
        tree.render(tree.confirmed, reveal: tree.received(token, withdrawn: true))
        #expect(tree.selection == clicked, "A later failure never steals a newer user selection")
    }

    @Test("Selecting away and back during a create is a newer selection", arguments: [false, true])
    func selectingAwayAndBackDuringCreateWins(afterReveal: Bool) throws {
        let tree = Tree()
        defer { tree.close() }
        try tree.click(tree.machineID)
        let token = UUID()
        tree.render(tree.existing, reveal: .init(token: token))
        if afterReveal {
            tree.render(tree.pending, reveal: tree.received(token))
            #expect(tree.selection == tree.createdID)
        }
        let returned = try #require(tree.selection)
        try tree.click(tree.fixture.folderID("ws_1"))
        try tree.click(returned)

        tree.render(tree.pending, reveal: tree.received(token))
        tree.render(tree.confirmed, reveal: tree.received(token))
        #expect(tree.selection == returned)
        tree.render(tree.confirmed, reveal: tree.received(token, withdrawn: true))
        #expect(tree.selection == returned, "The row the user came back to is theirs, not the create's baseline")
    }

    @Test("A tree mounted mid-create ignores the earlier request and follows the next one")
    func treeMountedDuringCreateIgnoresTheStaleRequest() throws {
        let stale = UUID()
        let tree = Tree(initial: .init(token: stale))
        defer { tree.close() }
        tree.render(tree.pending, reveal: tree.received(stale))
        tree.render(tree.confirmed, reveal: tree.received(stale))
        #expect(tree.selection == nil)

        let next = UUID()
        tree.render(tree.confirmed, reveal: .init(token: next))
        tree.render(tree.confirmed, reveal: .init(token: next, machine: tree.fixture.machine, remoteWorkspaceID: "ws_2"))
        #expect(tree.selection == tree.fixture.folderID("ws_2"))
    }

    @Test("A row the outline view has not selected yet is asked for again on the next update")
    func unselectedRowIsRequestedAgain() throws {
        var presentation = CloudTreeCreationRevealPresentation()
        let baseline = "machine:retry"
        #expect(presentation.update(request: nil, selectedNodeID: baseline) { _ in true } == nil)
        let reveal = CloudWorkspaceCreationReveal(token: UUID(), machine: .cloud("retry"), remoteWorkspaceID: "ws_1")
        let id = try #require(reveal.nodeID)

        #expect(presentation.update(request: reveal, selectedNodeID: baseline) { _ in true } == .select(id))
        #expect(presentation.update(request: reveal, selectedNodeID: baseline) { _ in true } == .select(id),
                "An unresolved row must not end the reveal")
        presentation.didSelect(id)
        #expect(presentation.update(request: reveal, selectedNodeID: id) { _ in true } == nil)
        var withdrawn = reveal
        withdrawn.isWithdrawn = true
        #expect(presentation.update(request: withdrawn, selectedNodeID: id) { _ in true } == .restore(baseline))
    }

    @MainActor
    private final class Tree {
        let fixture = CloudSidebarOrderingFixture()
        let pendingLocalWorkspaceID = UUID()
        var machineID: String { CloudTreeNodeBuilder.nodeID(machine: fixture.machine) }
        var createdID: String { fixture.folderID("ws_3") }

        init(initial: CloudWorkspaceCreationReveal? = nil) {
            render(existing, reveal: initial)
        }

        func close() { fixture.close() }

        func render(_ snapshot: SurfaceCatalogSnapshot, reveal: CloudWorkspaceCreationReveal?) {
            fixture.coordinator.update(inputs: .init(machines: [], snapshot: snapshot, source: .cloudWithDevicesSection))
            fixture.coordinator.reveal(creation: reveal)
        }

        var existing: SurfaceCatalogSnapshot { fixture.snapshot() }

        /// The receipt's row, before the daemon's graph lists its starter terminal.
        var pending: SurfaceCatalogSnapshot {
            var snapshot = confirmed
            snapshot.resources.removeAll { $0.remoteWorkspace?.id == "ws_3" }
            snapshot.pendingWorkspaceCreations = [fixture.machine: ["ws_3": pendingLocalWorkspaceID]]
            return snapshot
        }

        var confirmed: SurfaceCatalogSnapshot { fixture.snapshot(titles: ["cmux1", "cmux2", "cmux3"]) }

        func received(_ token: UUID, withdrawn: Bool = false) -> CloudWorkspaceCreationReveal {
            .init(token: token, machine: fixture.machine, remoteWorkspaceID: "ws_3", isWithdrawn: withdrawn)
        }

        func outline() throws -> CloudTreeNSOutlineView { try #require(fixture.coordinator.outlineView) }

        func node(_ id: String) throws -> CloudTreeNode {
            try #require(CloudTreeNodeBuilder.flattened(fixture.coordinator.nodes).first { $0.id == id })
        }

        var selection: String? {
            guard let outline = fixture.coordinator.outlineView, outline.selectedRow >= 0 else { return nil }
            return (outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id
        }

        /// A user selection: AppKit reports it outside a programmatic update.
        func click(_ id: String) throws {
            let outline = try outline()
            let row = outline.row(forItem: try node(id))
            try #require(row >= 0)
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @MainActor
    private final class SelectionLog {
        private(set) var selections: [String?] = []
        private var observer: NSObjectProtocol?

        init(outline: NSOutlineView) {
            observer = NotificationCenter.default.addObserver(
                forName: NSOutlineView.selectionDidChangeNotification, object: outline, queue: nil
            ) { [weak self, weak outline] _ in
                MainActor.assumeIsolated {
                    guard let self, let outline else { return }
                    let row = outline.selectedRow
                    self.selections.append(row < 0 ? nil : (outline.item(atRow: row) as? CloudTreeNode)?.id)
                }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
