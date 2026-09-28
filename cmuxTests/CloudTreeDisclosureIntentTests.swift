import AppKit
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
        tree.outline.expandItem(tree.resources)
        tree.outline.collapseItem(tree.ports)
        let events = Counter()
        let token = NotificationCenter.default.addUserDefaultsObserver(object: fixture.defaults) { events.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        tree.outline.collapseItem(tree.section)
        #expect(events.count == 1)
        #expect(fixture.defaults.object(forKey: "cloudTree.collapsedMachineIDs") == nil)
        let restored = CloudTreeExpansionStore(defaults: fixture.defaults)
        #expect(restored.isExpanded(tree.machine))
        #expect(restored.isExpanded(tree.resources))
        #expect(!restored.isExpanded(tree.ports))
        tree.outline.expandItem(tree.section)
        #expect(events.count == 2)
        #expect(tree.outline.isItemExpanded(tree.machine))
        #expect(tree.outline.isItemExpanded(tree.resources))
        #expect(!tree.outline.isItemExpanded(tree.ports))
        #expect(refreshes == 0, "Revealing an already-open group is not a new discovery request")

        tree.outline.selectRowIndexes(IndexSet(integer: tree.outline.row(forItem: tree.ports)), byExtendingSelection: false)
        fixture.coordinator.performDisclosure(.expand)
        #expect(refreshes == 1, "An explicit Ports expansion still discovers ports")
    }

    @Test func explicitRecursiveActionsPersistEachChangedKeyOnce() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try tree(fixture)
        tree.outline.expandItem(tree.resources)
        let events = Counter()
        let token = NotificationCenter.default.addUserDefaultsObserver(object: fixture.defaults) { events.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        var refreshes = 0
        fixture.coordinator.nodeActions.refreshMachine = { _ in refreshes += 1 }

        tree.outline.collapseItem(tree.section, collapseChildren: true)
        #expect(events.count == 3, "Machine, collapsed-node and expanded-node keys each change once")
        let collapsed = CloudTreeExpansionStore(defaults: fixture.defaults)
        #expect(!collapsed.isExpanded(tree.machine))
        #expect(!collapsed.isExpanded(tree.ports))
        #expect(!collapsed.isExpanded(tree.resources))
        events.count = 0
        tree.outline.expandItem(tree.section, expandChildren: true)
        #expect(events.count == 3)
        #expect(refreshes == 1, "Ports and Displays share one machine discovery request")
        let expanded = CloudTreeExpansionStore(defaults: fixture.defaults)
        #expect(expanded.isExpanded(tree.machine))
        #expect(expanded.isExpanded(tree.ports))
        #expect(expanded.isExpanded(tree.resources))
    }

    @Test func nativeDisclosureClickPersistsOnlyTheClickedItem() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try tree(fixture)
        fixture.container.layoutSubtreeIfNeeded()
        let rect = tree.outline.frameOfOutlineCell(atRow: tree.outline.row(forItem: tree.section))
        let point = tree.outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        let events = Counter()
        let token = NotificationCenter.default.addUserDefaultsObserver(object: fixture.defaults) { events.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        NSApp.postEvent(up, atStart: true)
        tree.outline.mouseDown(with: down)
        #expect(!tree.outline.isItemExpanded(tree.section))
        #expect(events.count == 1)
        #expect(fixture.defaults.object(forKey: "cloudTree.collapsedMachineIDs") == nil)
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
        ports: CloudTreeNode, resources: CloudTreeNode
    ) {
        fixture.coordinator.update(inputs: .init(
            machines: [], snapshot: fixture.snapshot(), source: .cloudWithDevicesSection
        ))
        let outline = try #require(fixture.coordinator.outlineView)
        let section = try #require(fixture.coordinator.nodes.first)
        let machine = try #require(section.children.first)
        let ports = try #require(machine.children.first { $0.structureTag == "portsGroup" })
        let resources = try #require(machine.children.first { $0.structureTag == "resourcesPool" })
        return (outline, section, machine, ports, resources)
    }

    @MainActor private final class Counter { var count = 0 }
}
