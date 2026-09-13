import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud notification persistence")
struct CloudNotificationSyncStoreTests {
    @Test
    func providerReplacementReadsQueuedDeliveryAndForgetCannotResurrectIt() async throws {
        let suite = "CloudNotificationSyncStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudNotificationSyncStore(defaults: defaults)
        var deliveries = 0
        func makeSync() -> CloudNotificationSync {
            CloudNotificationSync(
                machineID: "machine", clientID: "mac", store: store,
                resolveTarget: { _ in .init(workspaceID: UUID(), panelID: nil) },
                deliver: { _, _ in deliveries += 1; return true }, send: { _ in }
            )
        }
        let row = CloudVMNotificationRow(
            id: "n1", title: "Done", subtitle: nil, body: "", level: "info",
            createdAtMs: 1, terminalID: "t1", readBy: []
        )
        let original = makeSync()
        original.apply(rows: [row])
        original.retire()
        let replacement = makeSync()
        replacement.apply(rows: [row])
        #expect(deliveries == 1, "Replacement must see the queued delivery before preferences finish writing.")
        #expect(replacement.state.delivered == [row.id])
        replacement.forget()
        original.noteRead(notificationIDs: [row.id])
        await store.flush()
        #expect(defaults.data(forKey: CloudNotificationSyncStore.key(machineID: "machine")) == nil)
        #expect(store.load(machineID: "machine") == CloudNotificationSyncState())
    }

    @Test
    func writesDrainInOrderAcrossBatchesAndMachines() async throws {
        let suite = "CloudNotificationSyncStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudNotificationSyncStore(defaults: defaults)
        store.save(.init(delivered: ["old"]), machineID: "a")
        // Let the first batch start; the invariant is independent of whether
        // that write finishes before the next mutation is enqueued.
        await Task.yield()
        store.remove(machineID: "a")
        let final = CloudNotificationSyncState(delivered: ["new"], pendingAcks: [.init(key: "k", ids: ["n"])])
        store.save(final, machineID: "a")
        store.save(.init(delivered: ["other"]), machineID: "b")
        await store.flush()
        #expect(!store.hasPendingWrites)
        let restored = CloudNotificationSyncStore(defaults: defaults)
        #expect(restored.load(machineID: "a") == final)
        #expect(restored.load(machineID: "b").delivered == ["other"])
    }

    @Test
    func acknowledgementIsPersistedBeforeSendingAndDrainedAfterSuccess() async throws {
        let suite = "CloudNotificationSyncStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudNotificationSyncStore(defaults: defaults)
        var sent = 0
        let sync = CloudNotificationSync(
            machineID: "machine", clientID: "mac", store: store,
            newKey: { "ack-key" }, resolveTarget: { _ in nil }, deliver: { _, _ in true },
            send: { batch in
                let data = try #require(defaults.data(forKey: CloudNotificationSyncStore.key(machineID: "machine")))
                let saved = try JSONDecoder().decode(CloudNotificationSyncState.self, from: data)
                #expect(saved.pendingAcks == [batch])
                sent += 1
            }
        )
        defer { sync.retire() }
        sync.noteRead(notificationIDs: ["n1"])
        await sync.flushPendingReads()
        #expect(sent == 1)
        #expect(sync.state.pendingAcks.isEmpty)
        #expect(CloudNotificationSyncStore(defaults: defaults).load(machineID: "machine").pendingAcks.isEmpty)
    }

    @Test
    func readByOnlyChangeStillRefreshesUnreadWithoutChangingSyncState() async throws {
        let suite = "CloudNotificationSyncStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudNotificationSyncStore(defaults: defaults)
        var unreadChanges: [Set<String>] = []
        let sync = CloudNotificationSync(
            machineID: "machine", clientID: "mac", store: store,
            resolveTarget: { _ in .init(workspaceID: UUID(), panelID: nil) },
            deliver: { _, _ in true }, send: { _ in }, unreadChanged: { unreadChanges.append($0) }
        )
        defer { sync.retire() }
        var row = CloudVMNotificationRow(
            id: "n1", title: "Done", subtitle: nil, body: "", level: "info",
            createdAtMs: 1, terminalID: "t1", readBy: []
        )
        sync.apply(rows: [row])
        let state = sync.state
        row.readBy = ["mac"]
        sync.apply(rows: [row])
        await store.flush()
        #expect(sync.state == state)
        #expect(unreadChanges == [["t1"], []])
    }
}
