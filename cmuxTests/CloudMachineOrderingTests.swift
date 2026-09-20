import AppKit
import CmuxCloudMachines
import Observation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud machine ordering", .serialized)
struct CloudMachineOrderingTests {
    @Test("Header edges move whole machines and retain selection and expansion",
          arguments: [false, true], [false, true])
    func headers(collapsed: Bool, after: Bool) throws {
        let fixture = CloudMachineOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let source = try fixture.root(after ? "a" : "d")
        let target = try fixture.root(after ? "d" : "a")
        let children = source.children
        if collapsed { outline.collapseItem(target) }
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: source)), byExtendingSelection: false)
        let drag = try fixture.begin(try #require(source.machineOrderID))
        let rect = outline.rect(ofRow: outline.row(forItem: target))
        drag.info.draggingLocation = outline.convert(
            NSPoint(x: rect.midX, y: after ? rect.maxY - 1 : rect.minY + 1), to: nil
        )
        let before = fixture.base.defaults.data(forKey: CloudMachinePinStore.defaultsKey)
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: target, proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move)
        #expect(fixture.base.defaults.data(forKey: CloudMachinePinStore.defaultsKey) == before)
        let line = try #require(outline.subviews.first { $0.identifier?.rawValue == "sidebarReorderIndicator" })
        #expect(!line.isHidden && line.frame.height == 2)
        #expect(line.frame.minX == outline.visibleRect.minX + 8)
        let edge = after ? outline.rect(ofRow: outline.numberOfRows - 1).maxY - 2 : rect.minY
        #expect(line.frame.minY == edge)
        #expect(coordinator.outlineView(outline, acceptDrop: drag.info, item: nil, childIndex: after ? 5 : 1))
        #expect(fixture.order == (after ? ["b", "c", "d", "a"] : ["d", "a", "b", "c"]))
        #expect(line.isHidden)
        #expect((outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id == source.id)
        #expect(outline.isItemExpanded(target) == !collapsed)
        let moved = try fixture.root(try #require(source.machineOrderID))
        #expect(zip(moved.children, children).allSatisfy { pair in pair.0 === pair.1 })
        try fixture.end(drag)
        let restored = CloudMachinePinStore(defaults: fixture.base.defaults, scopeProvider: { "user:a|team:one" })
        #expect(restored.orderedMachineIDs(["a", "b", "c", "d"]) == fixture.order)
        #expect(fixture.base.provider.moved.isEmpty && fixture.base.provider.projected.isEmpty)
        #expect(fixture.base.provider.refreshCount == 0)
    }

    @Test("Crossing the pin boundary clamps both the move and insertion line", arguments: [false, true])
    func pinBoundary(pinnedSource: Bool) throws {
        let fixture = CloudMachineOrderingFixture()
        defer { fixture.close() }
        fixture.store.setPinned(true, machineID: "a")
        fixture.store.setPinned(true, machineID: "b")
        fixture.render()
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let drag = try fixture.begin(pinnedSource ? "a" : "d")
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: nil, proposedChildIndex: pinnedSource ? 5 : 0) == .move)
        let line = try #require(outline.subviews.first { $0.identifier?.rawValue == "sidebarReorderIndicator" })
        let boundary = outline.rect(ofRow: outline.row(forItem: try fixture.root("c"))).minY
        #expect(line.frame.minY == boundary)
        #expect(coordinator.outlineView(outline, acceptDrop: drag.info, item: nil, childIndex: 3))
        #expect(fixture.order == (pinnedSource ? ["b", "a", "c", "d"] : ["a", "b", "d", "c"]))
        #expect(fixture.store.pinnedMachineIDs == ["a", "b"])
        #expect(coordinator.nodes.filter(\.isPinned).compactMap(\.machineOrderID).count == 2)
        try fixture.end(drag)
    }

    @Test("Child hovering targets the machine's outer edge without moving descendants")
    func childHover() throws {
        let fixture = CloudMachineOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let target = try fixture.root("b")
        let terminal = try #require(CloudTreeNodeBuilder.flattened([target]).first { $0.isDragSource })
        let contents = CloudTreeNodeBuilder.flattened([target]).map(\.id)
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: terminal)), byExtendingSelection: false)
        let drag = try fixture.begin("a")
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: terminal, proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move)
        #expect(coordinator.outlineView(outline, acceptDrop: drag.info, item: nil, childIndex: 3))
        #expect(fixture.order == ["b", "a", "c", "d"])
        #expect(CloudTreeNodeBuilder.flattened([try fixture.root("b")]).map(\.id) == contents)
        #expect((outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id == terminal.id)
        #expect(fixture.base.catalog.sidebarOrganization.state.groups.isEmpty)
        try fixture.end(drag)
    }

    @Test("Live refresh uses the frozen drop geometry and latest identities", arguments: [false, true])
    func liveRefresh(accept: Bool) throws {
        let fixture = CloudMachineOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let drag = try fixture.begin("d")
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: nil, proposedChildIndex: 1) == .move)
        fixture.update(ids: ["new", "d", "c", "a"], titlePrefix: "fresh-")
        fixture.store.reconcile(machineIDs: ["new", "d", "c", "a"])
        #expect(fixture.order == ["a", "b", "c", "d"])
        #expect(coordinator.deferredNodes != nil)
        if accept {
            #expect(coordinator.outlineView(outline, acceptDrop: drag.info, item: nil, childIndex: 1))
            #expect(fixture.order == ["d", "a", "c", "new"], "Accepted order appears before source completion")
        }
        try fixture.end(drag)
        #expect(fixture.order == (accept ? ["d", "a", "c", "new"] : ["a", "c", "d", "new"]))
        #expect(coordinator.nodes.filter(\.canReorderMachine).allSatisfy { $0.searchableTitle.hasPrefix("fresh-") })
        #expect(coordinator.deferredNodes == nil)
        #expect(outline.subviews.filter { $0.identifier?.rawValue == "sidebarReorderIndicator" }.allSatisfy(\.isHidden))
        #expect(!coordinator.outlineView(outline, acceptDrop: drag.info, item: nil, childIndex: 1))
    }

    @Test("Deleted identities, changed pins and retired accounts reject old drops",
          arguments: ["source", "target", "account", "round-trip", "pin"])
    func staleDrop(change: String) throws {
        let fixture = CloudMachineOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let drag = try fixture.begin("d")
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: nil, proposedChildIndex: 1) == .move)
        switch change {
        case "source": fixture.input.snapshot = fixture.snapshot(ids: ["a", "b", "c"])
        case "target": fixture.input.snapshot = fixture.snapshot(ids: ["b", "c", "d"])
        case "account", "round-trip":
            fixture.input.scope = "user:b|team:one"
            fixture.model.resetForAuthTransition()
            fixture.store.refreshScope()
            fixture.update(ids: ["a", "b", "c", "d"])
            if change == "round-trip" {
                fixture.input.scope = "user:a|team:one"
                fixture.model.resetForAuthTransition()
                fixture.store.refreshScope()
                fixture.update(ids: ["a", "b", "c", "d"])
            }
        default: fixture.store.setPinned(true, machineID: "d")
        }
        let before = fixture.base.defaults.data(forKey: CloudMachinePinStore.defaultsKey)
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: nil, proposedChildIndex: 1).isEmpty)
        #expect(!coordinator.outlineView(outline, acceptDrop: drag.info, item: nil, childIndex: 1))
        #expect(fixture.base.defaults.data(forKey: CloudMachinePinStore.defaultsKey) == before)
        try fixture.end(drag)
    }

    @Test("Foreign sources, obsolete sessions, self drops and singleton tiers do not move")
    func invalidSourcesAndNoOps() throws {
        let fixture = CloudMachineOrderingFixture(ids: ["a", "b"])
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let drag = try fixture.begin("b")
        let foreign = CloudSidebarDraggingInfo(
            source: NSOutlineView(), pasteboard: drag.info.draggingPasteboard,
            location: .zero, sequenceNumber: drag.session.draggingSequenceNumber
        )
        #expect(coordinator.outlineView(outline, validateDrop: foreign, proposedItem: nil, proposedChildIndex: 1).isEmpty)
        let stale = CloudSidebarDraggingInfo(
            source: outline, pasteboard: drag.info.draggingPasteboard,
            location: .zero, sequenceNumber: drag.session.draggingSequenceNumber - 1
        )
        #expect(!coordinator.outlineView(outline, acceptDrop: stale, item: nil, childIndex: 1))
        #expect(coordinator.outlineView(outline, validateDrop: drag.info, proposedItem: nil, proposedChildIndex: 3).isEmpty)
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: try fixture.root("b"), proposedChildIndex: NSOutlineViewDropOnItemIndex).isEmpty)
        try fixture.end(drag)
        fixture.store.setPinned(true, machineID: "a")
        fixture.render()
        let singleton = try fixture.begin("b")
        #expect(coordinator.outlineView(outline, validateDrop: singleton.info,
            proposedItem: nil, proposedChildIndex: 0).isEmpty)
        #expect(fixture.order == ["a", "b"])
        #expect(fixture.store.pinnedMachineIDs == ["a"])
        try fixture.end(singleton)
    }

    @Test("This Mac and pending creates stay fixed, including adopted machine IDs")
    func specialRows() throws {
        let fixture = CloudMachineOrderingFixture()
        defer { fixture.close() }
        fixture.pending = [MachineCreateOperation(
            id: UUID(), request: MachineCreateCoordinatorTests.newMachineRequest(),
            startedAt: Date(timeIntervalSince1970: 1)
        )]
        fixture.adoptedIDs["d"] = UUID()
        fixture.render()
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let anchors = Array(coordinator.nodes.prefix(2))
        let adopted = try fixture.root("d").id
        let drag = try fixture.begin("d")
        for node in anchors {
            #expect(coordinator.outlineView(outline, pasteboardWriterForItem: node) == nil)
            #expect(coordinator.outlineView(outline, validateDrop: drag.info,
                proposedItem: node, proposedChildIndex: NSOutlineViewDropOnItemIndex).isEmpty)
        }
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: nil, proposedChildIndex: 0) == .move)
        #expect(coordinator.outlineView(outline, acceptDrop: drag.info, item: nil, childIndex: 2))
        #expect(Array(coordinator.nodes.prefix(2)).map(\.id) == anchors.map(\.id))
        #expect(fixture.order == ["d", "a", "b", "c"])
        #expect(try fixture.root("d").id == adopted)
        try fixture.end(drag)
    }

    @Test("Menus, focused keyboard routing and accessibility share persisted moves")
    func commandParity() throws {
        let fixture = CloudMachineOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let source = try fixture.root("d")
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: source)), byExtendingSelection: false)
        try fixture.choose(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top"), machineID: "d")
        #expect(fixture.order == ["d", "a", "b", "c"])
        #expect(fixture.base.window.makeFirstResponder(outline))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .control, .option],
            timestamp: 0, windowNumber: fixture.base.window.windowNumber, context: nil,
            characters: "]", charactersIgnoringModifiers: "]", isARepeat: false, keyCode: 30
        ))
        let app = try #require(AppDelegate.shared)
        #expect(app.moveFocusedCloudMachine(by: 1, event: event))
        #expect(fixture.order == ["a", "d", "b", "c"])
        let fixedOrder = fixture.order
        let child = try #require(CloudTreeNodeBuilder.flattened([try fixture.root("a")]).first { $0.isDragSource })
        for selected in [coordinator.nodes[0], child] {
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: selected)), byExtendingSelection: false)
            #expect(app.moveFocusedCloudMachine(by: -1, event: event))
            #expect(fixture.order == fixedOrder)
        }
        outline.deselectAll(nil)
        #expect(app.moveFocusedCloudMachine(by: 1, event: event))
        #expect(fixture.order == fixedOrder)
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: try fixture.root("d"))), byExtendingSelection: false)
        let cell = try #require(coordinator.outlineView(outline, viewFor: outline.outlineTableColumn, item: try fixture.root("d")))
        let down = try #require(cell.accessibilityCustomActions()?.first {
            $0.name == String(localized: "contextMenu.moveDown", defaultValue: "Move Down")
        })
        #expect(down.handler?() == true)
        #expect(fixture.order == ["a", "b", "d", "c"])
        try fixture.choose(String(localized: "machines.row.pin", defaultValue: "Pin Machine"), machineID: "d")
        #expect(fixture.order == ["d", "a", "b", "c"])
        #expect(coordinator.moveSelectedMachine(by: 1))
        #expect(fixture.order == ["d", "a", "b", "c"], "A boundary key is consumed without changing pin membership")
        try fixture.choose(String(localized: "machines.row.unpin", defaultValue: "Unpin Machine"), machineID: "d")
        #expect(fixture.order == ["d", "a", "b", "c"])
        let restored = CloudMachinePinStore(defaults: fixture.base.defaults, scopeProvider: { "user:a|team:one" })
        #expect(restored.orderedMachineIDs(["c", "b", "a", "d"]) == fixture.order)
        #expect(restored.pinnedMachineIDs.isEmpty)
    }

    @Test("Accessibility availability follows pin boundaries without repainting peers")
    func accessibilityAvailability() throws {
        let fixture = CloudMachineOrderingFixture(ids: ["a", "b"])
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let cell = try #require(coordinator.outlineView(outline, viewFor: outline.outlineTableColumn, item: try fixture.root("b")))
        #expect(cell.accessibilityCustomActions()?.map(\.name) == [
            String(localized: "contextMenu.moveUp", defaultValue: "Move Up"),
            String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")
        ])
        fixture.store.setPinned(true, machineID: "a")
        #expect(cell.accessibilityCustomActions()?.isEmpty == true)
        fixture.store.setPinned(false, machineID: "a")
        #expect(cell.accessibilityCustomActions()?.count == 2)
    }

    @Test("Both panels observe moves through the existing pin/order store")
    func sharedOrderObservation() async throws {
        let fixture = CloudMachineOrderingFixture()
        defer { fixture.close() }
        let second = MachinesPanelViewModel(
            createCoordinator: MachineCreateCoordinator(notifier: { _ in }, notificationCenter: NotificationCenter()),
            machinePinStore: fixture.store, catalogProvider: { fixture.input.snapshot }
        )
        second.localWorkspacesProvider = { [] }
        second.readCatalog()
        let actions = try #require(fixture.coordinator.machineActions.ordering)
        await confirmation("Both order readers invalidate", expectedCount: 2) { changed in
            withObservationTracking { _ = fixture.model.sidebarMachines } onChange: { changed() }
            withObservationTracking { _ = second.sidebarMachines } onChange: { changed() }
            #expect(actions.move("d", .top) != nil)
        }
        #expect(fixture.model.sidebarMachines.map(\.id) == ["d", "a", "b", "c"])
        #expect(second.sidebarMachines.map(\.id) == ["d", "a", "b", "c"])
    }
}
