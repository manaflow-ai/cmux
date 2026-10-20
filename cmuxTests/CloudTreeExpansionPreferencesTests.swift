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
@Suite("Cloud tree private restoration persistence", .serialized)
struct CloudTreeExpansionPreferencesTests {
    @Test func productionPersistenceIsSilentAndKeepsLegacyKeys() async throws {
        let domain = "cloud-expansion-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let key = "cloudTree.collapsedNodeIDs"
        defaults.set(["old-section"], forKey: key)
        let preferences = CloudTreeExpansionPreferences(applicationID: domain)
        let store = CloudTreeExpansionStore(defaults: preferences)
        let section = CloudTreeNode(id: "old-section", kind: .cloudMachinesSection(canCreateMachine: false))
        #expect(!store.isExpanded(section), "Existing installations keep their expansion choices")
        let tally = Tally()
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in
            if Thread.isMainThread { MainActor.assumeIsolated { tally.count += 1 } }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let flushToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in continuation.yield(()) }
        defer { NotificationCenter.default.removeObserver(flushToken) }
        let notifications = Task {
            var count = 0
            for await _ in events { count += 1 }
            return count
        }
        for _ in 0..<20 {
            store.setExpanded(true, node: section)
            store.setExpanded(false, node: section)
        }
        #expect(tally.count == 0, "A disclosure must not enter any app-wide settings observer")
        #expect(preferences.stringArray(forKey: key) == [section.id])
        #expect(await preferences.flush())
        let restored = CloudTreeExpansionStore(defaults: CloudTreeExpansionPreferences(applicationID: domain))
        #expect(!restored.isExpanded(section))
        store.setExpanded(true, node: section)
        #expect(await preferences.flush())
        #expect(preferences.stringArray(forKey: key) == [])
        continuation.finish()
        #expect(await notifications.value == 0, "Background flushes must not broadcast settings changes either")
    }

    @Test func defaultDomainReadsAndWritesTheTestHostsExistingPreferences() async {
        let key = "cloudTree.test.\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defaults.set(["legacy"], forKey: key)
        defer { defaults.removeObject(forKey: key) }
        let preferences = CloudTreeExpansionPreferences()
        #expect(preferences.stringArray(forKey: key) == ["legacy"])
        #expect(preferences.setIfChanged(["updated"], forKey: key))
        #expect(await preferences.flush())
        #expect(defaults.stringArray(forKey: key) == ["updated"])
    }

    @Test func interruptedLegacyWriteKeepsExplicitCollapseAfterReload() throws {
        let domain = "cloud-expansion-conflict-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let section = CloudTreeNode(id: "resources", kind: .resourcesPool(machine: .cloud("test"), count: 4))
        defaults.set([section.id], forKey: "cloudTree.collapsedNodeIDs")
        defaults.set([section.id], forKey: "cloudTree.expandedNodeIDs")
        let store = CloudTreeExpansionStore(defaults: defaults)
        #expect(!store.isExpanded(section))
        store.setExpanded(false, node: section)
        #expect(!CloudTreeExpansionStore(defaults: defaults).isExpanded(section))
        #expect(defaults.stringArray(forKey: "cloudTree.expandedNodeIDs") == [])
    }

    @Test func valuesAreSortedAndNoOpWritesAreSilent() throws {
        let domain = "cloud-expansion-arrays-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = CloudTreeExpansionStore(defaults: defaults)
        for id in ["z", "a", "m"] {
            store.setExpanded(false, node: CloudTreeNode(id: id, kind: .cloudMachinesSection(canCreateMachine: false)))
        }
        #expect(defaults.stringArray(forKey: "cloudTree.collapsedNodeIDs") == ["a", "m", "z"])
        #expect(!defaults.setIfChanged(["a", "m", "z"], forKey: "cloudTree.collapsedNodeIDs"))
    }

    @MainActor private final class Tally { var count = 0 }
}
