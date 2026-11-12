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
@Suite("Cloud tree disclosure work", .serialized)
struct CloudTreeTogglePerformanceTests {
    @Test func togglesWriteOnlyChangedExpansionKey() throws {
        let name = "cloud-toggle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CloudTreeExpansionStore(defaults: defaults)
        let section = CloudTreeNode(id: "cloud-machines-section", kind: .cloudMachinesSection(canCreateMachine: false))
        let tally = Tally()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in MainActor.assumeIsolated { tally.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.setExpanded(true, node: section)
        #expect(tally.count == 0, "An already-expanded section must not persist anything")
        tally.count = 0
        store.setExpanded(false, node: section)
        #expect(tally.count == 1, "Only collapsedNodeIDs changed")
        #expect(defaults.stringArray(forKey: "cloudTree.collapsedNodeIDs") == [section.id])
        #expect(defaults.object(forKey: "cloudTree.expandedNodeIDs") == nil)
        tally.count = 0
        store.setExpanded(false, node: section)
        #expect(tally.count == 0, "Repeated collapse must not notify any defaults observer")
        store.setExpanded(true, node: section)
        #expect(tally.count == 1)
    }

    @Test func reconcileWritesOnlyRemovedKeyAndPreservesTransientAbsence() throws {
        let name = "cloud-reconcile-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["missing"], forKey: "cloudTree.collapsedNodeIDs")
        let store = CloudTreeExpansionStore(defaults: defaults)
        let tally = Tally()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in MainActor.assumeIsolated { tally.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.reconcile(nodes: [])
        store.reconcile(nodes: [])
        #expect(tally.count == 0)
        store.reconcile(nodes: [])
        #expect(tally.count == 1)
        #expect(defaults.object(forKey: "cloudTree.collapsedMachineIDs") == nil)
        #expect(defaults.object(forKey: "cloudTree.expandedNodeIDs") == nil)
        store.reconcile(nodes: [])
        #expect(tally.count == 1)
    }

    @Test("Disclosure and unrelated renders do no catalog work", arguments: [10, 1_000], [false, true])
    func unchangedRendersDoNotRebuild(machineCount: Int, privatePreferences: Bool) async throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tally = Tally()
        let preferences = CloudTreeExpansionPreferences(applicationID: fixture.defaultsName)
        let expansion = privatePreferences
            ? CloudTreeExpansionStore(defaults: preferences)
            : CloudTreeExpansionStore(defaults: fixture.defaults)
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: fixture.coordinator.machineActions,
            nodeActions: fixture.coordinator.nodeActions,
            expansionStore: expansion,
            organization: fixture.catalog.sidebarOrganization,
            buildNodes: { inputs in
                tally.count += 1
                return inputs.nodes()
            },
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        fixture.window.contentView = container
        let inputs = CloudTreeBuildInputs(
            machines: (0..<machineCount).map { index in
                MachineSnapshot(id: "machine-\(index)", provider: "freestyle", image: "test",
                                isDesktop: false, activity: .ready)
            },
            snapshot: .empty,
            source: .cloudWithDevicesSection
        )
        coordinator.update(inputs: inputs)
        #expect(tally.count == 1)
        let outline = try #require(coordinator.outlineView)
        let section = try #require(coordinator.nodes.first)
        let pump = AppKitTestEventPump()
        container.layoutSubtreeIfNeeded()
        await pump.drain()
        container.layoutSubtreeIfNeeded()
        let notifications = Tally()
        let token = NotificationCenter.default.addUserDefaultsObserver(object: fixture.defaults) {
            notifications.count += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let start = ContinuousClock.now
        for _ in 0..<10 {
            outline.collapseItem(section)
            coordinator.update(inputs: inputs)
            await pump.drain()
            container.layoutSubtreeIfNeeded()
            outline.expandItem(section)
            coordinator.update(inputs: inputs)
            await pump.drain()
            container.layoutSubtreeIfNeeded()
        }
        let elapsed = start.duration(to: .now)
        if privatePreferences { #expect(await preferences.flush()) }
        print("Cloud toggle benchmark machines=\(machineCount) privatePreferences=\(privatePreferences) toggles=20 builds=\(tally.count - 1) notifications=\(notifications.count) viewportRows=\(outline.rows(in: outline.visibleRect).length) elapsed=\(elapsed)")
        #expect(tally.count == 1, "An unchanged-input update must not even call the node builder")
        #expect(notifications.count == (privatePreferences ? 0 : 20))
        #expect(coordinator.nodes.first === section)
        #expect(outline.isItemExpanded(section))
    }

    @MainActor private final class Tally {
        var count = 0
    }
}
