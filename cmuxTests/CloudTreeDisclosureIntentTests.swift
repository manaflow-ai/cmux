import AppKit
import CmuxAppKitSupportUI
import CmuxCloud
import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud disclosure intent", .serialized)
struct CloudTreeDisclosureIntentTests {
    @Test func parentVisibilityDoesNotChangeDescendantChoicesOrRefreshMachines() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try tree(fixture)
        var refreshes = 0
        fixture.coordinator.nodeActions.refreshMachine = { _ in refreshes += 1 }
        tree.outline.expandItem(tree.folder)
        tree.outline.collapseItem(tree.otherFolder)
        let events = Counter()
        let token = NotificationCenter.default.addUserDefaultsObserver(object: fixture.defaults) { events.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        tree.outline.collapseItem(tree.section)
        #expect(events.count == 1)
        #expect(fixture.defaults.object(forKey: "cloudTree.collapsedMachineIDs") == nil)
        let restored = CloudTreeExpansionStore(defaults: fixture.defaults)
        #expect(restored.isExpanded(tree.machine))
        #expect(restored.isExpanded(tree.folder))
        #expect(!restored.isExpanded(tree.otherFolder))
        tree.outline.expandItem(tree.section)
        #expect(events.count == 2)
        #expect(tree.outline.isItemExpanded(tree.machine))
        #expect(tree.outline.isItemExpanded(tree.folder))
        #expect(!tree.outline.isItemExpanded(tree.otherFolder))
        #expect(refreshes == 0, "Revealing an already-open group is not a new discovery request")

        tree.outline.selectRowIndexes(IndexSet(integer: tree.outline.row(forItem: tree.otherFolder)), byExtendingSelection: false)
        fixture.coordinator.performDisclosure(.expand)
        #expect(tree.outline.isItemExpanded(tree.otherFolder))
        #expect(refreshes == 0, "A workspace folder asks for no refresh; Ports and Displays refresh when their tab opens")
    }

    @Test func explicitRecursiveActionsPersistEachChangedKeyOnce() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try tree(fixture)
        tree.outline.expandItem(tree.folder)
        let events = Counter()
        let token = NotificationCenter.default.addUserDefaultsObserver(object: fixture.defaults) { events.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        var refreshes = 0
        fixture.coordinator.nodeActions.refreshMachine = { _ in refreshes += 1 }

        tree.outline.collapseItem(tree.section, collapseChildren: true)
        #expect(events.count == 3, "Machine, collapsed-node and expanded-node keys each change once")
        let collapsed = CloudTreeExpansionStore(defaults: fixture.defaults)
        #expect(!collapsed.isExpanded(tree.machine))
        #expect(!collapsed.isExpanded(tree.otherFolder))
        #expect(!collapsed.isExpanded(tree.folder))
        events.count = 0
        tree.outline.expandItem(tree.section, expandChildren: true)
        #expect(events.count == 3)
        #expect(refreshes == 0, "Workspace folders request no machine refresh")
        let expanded = CloudTreeExpansionStore(defaults: fixture.defaults)
        #expect(expanded.isExpanded(tree.machine))
        #expect(expanded.isExpanded(tree.otherFolder))
        #expect(expanded.isExpanded(tree.folder))
    }

    @Test func nativeDisclosureControlPersistsOnlyTheClickedItem() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try tree(fixture)
        fixture.container.layoutSubtreeIfNeeded()
        let row = tree.outline.row(forItem: tree.section)
        let button = try #require(descendants(of: tree.outline).compactMap { $0 as? NSButton }.first {
            $0.identifier == NSOutlineView.disclosureButtonIdentifier && tree.outline.row(for: $0) == row
        })
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hit = try #require(tree.outline.cmuxHitTest(windowPoint: center))
        #expect(hit === button || hit.isDescendant(of: button))
        let events = Counter()
        let token = NotificationCenter.default.addUserDefaultsObserver(object: fixture.defaults) { events.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        button.performClick(nil)
        #expect(!tree.outline.isItemExpanded(tree.section))
        #expect(events.count == 1)
        #expect(fixture.defaults.object(forKey: "cloudTree.collapsedMachineIDs") == nil)
    }

    @Test func rapidMultiClickRowActivationStillTogglesDisclosureRows() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try tree(fixture)
        let row = tree.outline.row(forItem: tree.section)
        tree.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        #expect(tree.outline.isItemExpanded(tree.section))

        // A fast pointer sequence can deliver the outline action while the
        // current event already carries the combined click count. Disclosure
        // rows must still honor that activation.
        try sendPointerAction(tree.outline.action, from: tree.outline, clickCount: 2)
        #expect(!tree.outline.isItemExpanded(tree.section))
        try sendPointerAction(tree.outline.action, from: tree.outline, clickCount: 3)
        #expect(tree.outline.isItemExpanded(tree.section))
    }

    @Test func fastDoubleClickActivationStillTogglesDisclosureRows() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try tree(fixture)
        let row = tree.outline.row(forItem: tree.section)
        tree.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        #expect(tree.outline.isItemExpanded(tree.section))

        // NSOutlineView routes the second click of a double-click through
        // doubleAction. Disclosure rows must honor that activation too.
        try sendPointerAction(tree.outline.doubleAction, from: tree.outline, clickCount: 2)
        #expect(!tree.outline.isItemExpanded(tree.section))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func sendPointerAction(_ action: Selector?, from outline: NSOutlineView, clickCount: Int) throws {
        let action = try #require(action)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 0
        ))
        NSApp.postEvent(event, atStart: true)
        let dequeued = try #require(NSApp.nextEvent(
            matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true
        ))
        try #require(dequeued.clickCount == clickCount)
        try #require(NSApp.currentEvent === dequeued)
        #expect(NSApp.sendAction(action, to: outline.target, from: outline))
    }

    @Test func nestedBatchesAndNetNoOpsDoNotWrite() throws {
        let name = "cloud-disclosure-batch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CloudTreeExpansionStore(defaults: defaults)
        let section = CloudTreeNode(id: "section", kind: .cloudMachinesSection(canCreateMachine: false))
        let events = Counter()
        let token = NotificationCenter.default.addUserDefaultsObserver(object: defaults) { events.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.withBatch {
            store.setExpanded(false, node: section)
            store.withBatch { store.setExpanded(true, node: section) }
        }
        #expect(events.count == 0)
        #expect(defaults.object(forKey: "cloudTree.collapsedNodeIDs") == nil)
    }

    private func tree(_ fixture: CloudSidebarOrderingFixture) throws -> (
        outline: CloudTreeNSOutlineView, section: CloudTreeNode, machine: CloudTreeNode,
        otherFolder: CloudTreeNode, folder: CloudTreeNode
    ) {
        fixture.coordinator.update(inputs: .init(
            machines: [], snapshot: fixture.snapshot(), source: .cloudWithDevicesSection
        ))
        let outline = try #require(fixture.coordinator.outlineView)
        let section = try #require(fixture.coordinator.nodes.first)
        let machine = try #require(section.children.first)
        // The workspace folders start closed under the machine; Ports,
        // Terminals, Displays and Resources are tabs on the machine's tab row.
        let folders = machine.children.filter { $0.structureTag == "workspace" }
        try #require(folders.count == 2)
        return (outline, section, machine, folders[1], folders[0])
    }

    @MainActor private final class Counter { var count = 0 }
}
