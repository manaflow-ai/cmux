import AppKit
import CmuxCloudMachines
import Observation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud machine ordering", .serialized)
struct CloudMachineOrderingTests {
    /// Machine drags show their destination by the rows parting, never a line.
    private func expectNoReorderIndicator(_ outline: NSOutlineView) {
        #expect(!outline.subviews.contains { $0 is SidebarReorderIndicatorView && !$0.isHidden })
    }

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
        expectNoReorderIndicator(outline)
        #expect(fixture.base.defaults.data(forKey: CloudMachinePinStore.defaultsKey) == before)
        #expect(coordinator.outlineView(outline, acceptDrop: drag.info, item: nil, childIndex: after ? 5 : 1))
        #expect(fixture.order == (after ? ["b", "c", "d", "a"] : ["d", "a", "b", "c"]))
        expectNoReorderIndicator(outline)
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

    @Test("Machines under the Cloud Machines section reorder by drag", arguments: [false, true])
    func sectionedDrag(toEnd: Bool) throws {
        let fixture = CloudMachineOrderingFixture(sectioned: true)
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let section = try #require(fixture.section)
        let drag = try fixture.begin(toEnd ? "a" : "d")
        // Between two machines AppKit proposes the section with a child index.
        let index = toEnd ? 4 : 0
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: section, proposedChildIndex: index) == .move)
        #expect(coordinator.outlineView(outline, acceptDrop: drag.info, item: section, childIndex: index))
        #expect(fixture.order == (toEnd ? ["b", "c", "d", "a"] : ["d", "a", "b", "c"]))
        #expect(coordinator.nodes.first?.id == section.id, "machines stay under the section")
        #expect(fixture.machines.contains { if case .machineEndSpacer = $0.kind { return true }; return false },
                "the section keeps its closing gap")
        try fixture.end(drag)
        let restored = CloudMachinePinStore(defaults: fixture.base.defaults, scopeProvider: { "user:a|team:one" })
        #expect(restored.orderedMachineIDs(["a", "b", "c", "d"]) == fixture.order)
    }

    @Test("A lifted drag closes open machines, drops where it shows the row, and reopens them")
    func liftedDrag() throws {
        let fixture = CloudMachineOrderingFixture(sectioned: true)
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        outline.expandItem(try #require(fixture.section))
        outline.expandItem(try fixture.root("b"))
        let source = try fixture.root("a")
        let drag = try fixture.begin("a")
        let press = outline.rect(ofRow: outline.row(forItem: source)).midY
        coordinator.beginMachineLift(drag.session, node: source, in: outline, pressY: press)
        #expect(outline.machineLift.isActive(sequence: drag.session.draggingSequenceNumber))
        #expect(!outline.isItemExpanded(try fixture.root("b")), "open machines close for the drag")
        #expect(outline.machineLift.sourceNodeID == source.id)

        // Carry the row to just above c's bottom edge: past b and c, short of d.
        let start = outline.rect(ofRow: outline.row(forItem: source))
        let c = outline.rect(ofRow: outline.row(forItem: try fixture.root("c")))
        drag.info.draggingLocation = outline.convert(NSPoint(x: start.midX, y: c.maxY - 2), to: nil)
        // AppKit's own proposal (on b, which alone would drop a after b) is
        // ignored while the lift owns the drag.
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: try fixture.root("b"), proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move)
        expectNoReorderIndicator(outline)
        #expect(outline.machineLift.slot == 2)
        #expect(coordinator.outlineView(outline, acceptDrop: drag.info, item: try fixture.root("b"),
            childIndex: NSOutlineViewDropOnItemIndex))
        #expect(fixture.order == ["b", "c", "a", "d"])
        #expect(!outline.machineLift.isActive(sequence: drag.session.draggingSequenceNumber))
        #expect(outline.isItemExpanded(try fixture.root("b")), "open machines come back open")
        try fixture.end(drag)
    }

    /// Where the held row's grab point shows, in window coordinates: its
    /// laid-out frame plus the lift's translation.
    private func heldPoint(_ outline: NSOutlineView, node: CloudTreeNode, grabOffset: CGFloat) throws -> CGFloat {
        let row = outline.row(forItem: node)
        let layer = try #require(outline.rowView(atRow: row, makeIfNecessary: false)?.layer)
        return outline.convert(NSPoint(x: 10, y: outline.rect(ofRow: row).minY + layer.transform.m42 + grabOffset), to: nil).y
    }

    /// Fourteen open machines under the Cloud Machines section, scrolled to the bottom.
    private func scrolledOpenFixture() throws -> (CloudMachineOrderingFixture, NSClipView, [String]) {
        let ids = (0..<14).map { String(format: "m%02d", $0) }
        let fixture = CloudMachineOrderingFixture(ids: ids, sectioned: true)
        let outline = try #require(fixture.coordinator.outlineView)
        let clip = try #require(outline.enclosingScrollView?.contentView)
        outline.expandItem(try #require(fixture.section))
        for id in ids { outline.expandItem(try fixture.root(id), expandChildren: true) }
        fixture.base.container.layoutSubtreeIfNeeded()
        var bottom = clip.bounds
        bottom.origin.y = .greatestFiniteMagnitude
        clip.scroll(to: clip.constrainBoundsRect(bottom).origin)
        outline.enclosingScrollView?.reflectScrolledClipView(clip)
        fixture.base.container.layoutSubtreeIfNeeded()
        #expect(clip.bounds.minY > 100, "the list scrolls: \(clip.bounds.minY)")
        return (fixture, clip, fixture.order)
    }

    /// The scroll view's insets and inset mode, which a lift may change only while it lasts.
    private func insets(_ outline: NSOutlineView) -> [CGFloat] {
        guard let scrollView = outline.enclosingScrollView else { return [] }
        let insets = scrollView.contentInsets
        return [insets.top, insets.bottom, scrollView.automaticallyAdjustsContentInsets ? 1 : 0]
    }

    @Test("Closing open machines above the held one is not a move, and the row stays under the hand")
    func liftedDragBelowOpenMachines() async throws {
        let fixture = CloudMachineOrderingFixture(sectioned: true)
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        outline.expandItem(try #require(fixture.section))
        let a = try fixture.root("a")
        let b = try fixture.root("b")
        outline.expandItem(a, expandChildren: true)
        outline.expandItem(b, expandChildren: true)
        fixture.base.container.layoutSubtreeIfNeeded()
        let source = try fixture.root("c")
        let frame = outline.rect(ofRow: outline.row(forItem: source))
        let hand = outline.convert(NSPoint(x: 10, y: frame.midY), to: nil)
        let resting = insets(outline)
        let drag = try fixture.begin("c")
        coordinator.beginMachineLift(drag.session, node: source, in: outline, pressY: frame.midY)
        #expect(!outline.isItemExpanded(a) && !outline.isItemExpanded(b))
        // Past any glide the lift could run on its own.
        try await Task.sleep(for: .milliseconds(400))
        // A small nudge from where the hand pressed: a and b closed above c,
        // but only the pointer's travel counts.
        drag.info.draggingLocation = NSPoint(x: hand.x, y: hand.y - 3)
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: nil, proposedChildIndex: 0).isEmpty)
        #expect(outline.machineLift.slot == 2, "c keeps its place among a, b and d")
        let held = try heldPoint(outline, node: source, grabOffset: frame.height / 2)
        #expect(abs(held - drag.info.draggingLocation.y) < 1, "the row stays under the hand: \(held) vs \(drag.info.draggingLocation.y)")
        try fixture.end(drag)
        #expect(fixture.order == ["a", "b", "c", "d"])
        #expect(outline.isItemExpanded(try fixture.root("a")))
        #expect(outline.isItemExpanded(try fixture.root("b")))
        #expect(insets(outline) == resting, "the lift gives its scroll range back: \(insets(outline)) vs \(resting)")
    }

    @Test("The bottom machine of a scrolled list stays under the hand, and a cancel restores the scroll")
    func liftedDragAtBottomOfScrolledList() async throws {
        let (fixture, clip, order) = try scrolledOpenFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        let scrolled = clip.bounds.minY
        let last = try #require(order.last)
        let source = try fixture.root(last)
        let frame = outline.rect(ofRow: outline.row(forItem: source))
        let hand = outline.convert(NSPoint(x: 10, y: frame.midY), to: nil)
        #expect(clip.bounds.contains(clip.convert(hand, from: nil)), "the bottom machine is on screen")
        let resting = insets(outline)
        let drag = try fixture.begin(last)
        coordinator.beginMachineLift(drag.session, node: source, in: outline, pressY: frame.midY)
        #expect(order.allSatisfy { id in (try? fixture.root(id)).map { !outline.isItemExpanded($0) } == true })
        try await Task.sleep(for: .milliseconds(400))
        // Up, inside the span: past its end the row resists the pointer.
        drag.info.draggingLocation = NSPoint(x: hand.x, y: hand.y + 3)
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: nil, proposedChildIndex: 0).isEmpty)
        #expect(outline.machineLift.slot == order.count - 1, "the bottom machine keeps the last place")
        let held = try heldPoint(outline, node: source, grabOffset: frame.height / 2)
        #expect(abs(held - drag.info.draggingLocation.y) < 1, "the row stays under the hand: \(held) vs \(drag.info.draggingLocation.y)")

        try fixture.end(drag)
        #expect(fixture.order == order)
        #expect(order.allSatisfy { id in (try? fixture.root(id)).map { outline.isItemExpanded($0) } == true })
        #expect(abs(clip.bounds.minY - scrolled) < 1, "a cancel puts the list back where it was: \(clip.bounds.minY) vs \(scrolled)")
        #expect(insets(outline) == resting, "the lift gives its scroll range back: \(insets(outline)) vs \(resting)")
    }

    @Test("Rows closing below the held machine leave every row reachable by scrolling")
    func liftedDragKeepsRowsReachable() throws {
        let (fixture, clip, order) = try scrolledOpenFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        // Second to last: the last machine's rows close below it too.
        let id = order[order.count - 2]
        let source = try fixture.root(id)
        let frame = outline.rect(ofRow: outline.row(forItem: source))
        let hand = outline.convert(NSPoint(x: 10, y: frame.midY), to: nil)
        let resting = insets(outline)
        let drag = try fixture.begin(id)
        coordinator.beginMachineLift(drag.session, node: source, in: outline, pressY: frame.midY)
        drag.info.draggingLocation = hand
        _ = coordinator.outlineView(outline, validateDrop: drag.info, proposedItem: nil, proposedChildIndex: 0)
        let held = try heldPoint(outline, node: source, grabOffset: frame.height / 2)
        #expect(abs(held - hand.y) < 1, "the row stays under the hand: \(held) vs \(hand.y)")

        // Scrolled all the way up mid-drag, the first row shows.
        var top = clip.bounds
        top.origin.y = -.greatestFiniteMagnitude
        clip.scroll(to: clip.constrainBoundsRect(top).origin)
        outline.enclosingScrollView?.reflectScrolledClipView(clip)
        fixture.base.container.layoutSubtreeIfNeeded()
        let first = try #require(outline.rowView(atRow: 0, makeIfNecessary: false)?.layer)
        let firstTop = outline.rect(ofRow: 0).minY + first.transform.m42
        #expect(firstTop >= clip.bounds.minY - 0.5, "the first row is reachable: \(firstTop) vs \(clip.bounds.minY)")
        try fixture.end(drag)
        #expect(insets(outline) == resting, "the lift gives its scroll range back: \(insets(outline)) vs \(resting)")
    }

    @Test("A lifted drag released on its own slot moves nothing and reopens machines")
    func liftedCancel() throws {
        let fixture = CloudMachineOrderingFixture(sectioned: true)
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let outline = try #require(coordinator.outlineView)
        outline.expandItem(try #require(fixture.section))
        outline.expandItem(try fixture.root("c"))
        let source = try fixture.root("b")
        let drag = try fixture.begin("b")
        let press = outline.rect(ofRow: outline.row(forItem: source)).midY
        coordinator.beginMachineLift(drag.session, node: source, in: outline, pressY: press)
        #expect(!outline.isItemExpanded(try fixture.root("c")))
        drag.info.draggingLocation = outline.convert(NSPoint(x: 10, y: press + 3), to: nil)
        #expect(coordinator.outlineView(outline, validateDrop: drag.info,
            proposedItem: nil, proposedChildIndex: 0).isEmpty)
        try fixture.end(drag)
        #expect(fixture.order == ["a", "b", "c", "d"])
        #expect(outline.machineLift.sourceNodeID == nil)
        #expect(outline.isItemExpanded(try fixture.root("c")))
    }

    @Test("Crossing the pin boundary clamps the move without drawing a hint", arguments: [false, true])
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
        expectNoReorderIndicator(outline)
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
        // Cloud workspaces start collapsed; open the machine's rows so the terminal has one.
        outline.expandItem(target, expandChildren: true)
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
        expectNoReorderIndicator(outline)
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

    @Test("Catalog-only machine roots retain the account pin tier")
    func catalogOnlyRootsKeepPinnedState() throws {
        let fixture = CloudMachineOrderingFixture(ids: ["a"])
        defer { fixture.close() }
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: fixture.input.snapshot, localWorkspaces: [],
            pinnedMachineIDs: ["a"], includeLocalMachine: false
        )
        let machine = try #require(nodes.first)
        #expect(machine.machineOrderID == "a")
        #expect(machine.isPinned)
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

    @Test("SwiftUI updates two StateObject-backed outlines without a view-model broadcast")
    func hostedPanelsObserveSharedOrder() async throws {
        let fixture = CloudMachineOrderingFixture()
        defer { fixture.close() }
        let secondModel = MachinesPanelViewModel(
            createCoordinator: MachineCreateCoordinator(notifier: { _ in }, notificationCenter: NotificationCenter()),
            machinePinStore: fixture.store, catalogProvider: { fixture.input.snapshot }
        )
        secondModel.localWorkspacesProvider = { [] }
        secondModel.readCatalog()
        let hosts = [fixture.model, secondModel].map {
            NSHostingView(rootView: CloudMachineOrderingTestPanel(model: $0, fixture: fixture))
        }
        let windows = hosts.map { host in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return window
        }
        defer { for window in windows { window.contentView = nil } }
        let outlines = try hosts.map { try #require(findOutline(in: $0)) }
        let coordinators = try outlines.map { try #require($0.delegate as? CloudTreeOutlineView.Coordinator) }
        #expect(coordinators.allSatisfy { $0.nodes.compactMap(\.machineOrderID) == ["a", "b", "c", "d"] })
        let actions = try #require(fixture.coordinator.machineActions.ordering)
        #expect(actions.move("d", .top) != nil)
        // Wait on the rendered order, allowing SwiftUI to schedule more than
        // one transaction. The deadline bounds a missing observation update.
        let expectedOrder = ["d", "a", "b", "c"]
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !coordinators.allSatisfy({ $0.nodes.compactMap(\.machineOrderID) == expectedOrder }),
              ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
            }
            for host in hosts { host.layoutSubtreeIfNeeded() }
        }
        #expect(coordinators.allSatisfy { $0.nodes.compactMap(\.machineOrderID) == expectedOrder })
    }

    private func findOutline(in view: NSView) -> CloudTreeNSOutlineView? {
        if let outline = view as? CloudTreeNSOutlineView { return outline }
        for child in view.subviews {
            if let outline = findOutline(in: child) { return outline }
        }
        return nil
    }
}
