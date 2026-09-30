#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
import CmuxCloud
import Foundation
import Testing

@Suite("Cloud workspace notification actions")
struct CloudWorkspaceNotificationReadTests {
    @Test @MainActor func markReadUsesRemoteWorkspaceIdentity() async throws {
        let suite = "cmux.tests.cloud-workspace-read.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudNotificationSyncStore(defaults: defaults)
        let hub = CloudNotificationSyncHub(persistenceStore: store)
        var unread: Set<String> = []
        let sync = CloudNotificationSync(
            machineID: "vm-a", clientID: "mac-a", store: store,
            resolveTarget: { _ in CloudNotificationDeliveryTarget(workspaceID: UUID()) },
            deliver: { _, _ in .delivered },
            send: { _ in },
            unreadChanged: { unread = $0 }
        )
        hub.register(sync, remoteWorkspaceID: { ["term-a": "workspace-a", "term-b": "workspace-b"][$0] })
        let a = CloudVMNotificationRow(id: "notification-a", title: "a", body: "", level: "info", createdAtMs: 1, terminalID: "term-a", readBy: [])
        let b = CloudVMNotificationRow(id: "notification-b", title: "b", body: "", level: "info", createdAtMs: 2, terminalID: "term-b", readBy: [])
        sync.apply(rows: [a, b])

        #expect(hub.noteRead(remoteWorkspaceID: "workspace-a", machineID: "vm-a") == [a.id])
        #expect(unread == [b.terminalID!])
        await sync.flushPendingReads()
        #expect(sync.state.pendingAcks.isEmpty)
    }
}
