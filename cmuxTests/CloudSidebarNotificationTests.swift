import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud sidebar notification identity")
struct CloudSidebarNotificationTests {
    @Test("Arrival moves the correct folder; read, replay and restart never move it again")
    func deliveryReadAndReconnect() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let owner = fixture.catalog.sidebarOrganization
        let target = CloudNotificationDeliveryTarget(workspaceID: UUID(), panelID: UUID())
        let row = notification("notification_1", terminal: "term_ws_2")
        var deliveries: [CloudNotificationDeliveryTarget] = []
        let persistence = CloudNotificationSyncStore(defaults: fixture.defaults)
        let sync = CloudNotificationSync(
            machineID: fixture.machine.rawValue, clientID: "fixture-client", store: persistence,
            resolveTarget: { _ in target },
            deliver: { notification, resolved in
                deliveries.append(resolved)
                owner.raiseNotification(resource: SurfaceResourceID(machine: fixture.machine, kind: .terminal, key: notification.terminalID!), nodes: fixture.nodes())
                return true
            }, send: { _ in }
        )
        defer { sync.retire() }
        sync.apply(rows: [row])
        #expect(deliveries == [target])
        let arranged = CloudSidebarOrganizationTree(nodes: fixture.nodes(unread: sync.unreadTerminalIDs)).arrange(using: owner.state)
        let group = try #require(CloudSidebarOrganizationTree(nodes: arranged).parent(of: fixture.folderID("ws_1")))
        #expect(group.children.map(\.id) == [fixture.folderID("ws_2"), fixture.folderID("ws_1")])
        #expect(group.children[0].hasUnreadDescendant)
        #expect(!group.children[1].hasUnreadDescendant)
        #expect(owner.perform(.down, id: fixture.folderID("ws_2"), nodes: arranged))
        let manualOrder = owner.state
        sync.apply(rows: [row])
        sync.linkDidConnect()
        #expect(deliveries == [target])
        #expect(owner.state == manualOrder)
        sync.noteRead(notificationIDs: [row.id])
        #expect(sync.unreadTerminalIDs.isEmpty)
        let read = CloudSidebarOrganizationTree(nodes: fixture.nodes(unread: sync.unreadTerminalIDs)).arrange(using: owner.state)
        #expect(!read.contains { $0.hasUnreadDescendant })
        sync.retire()
        let restarted = CloudNotificationSync(machineID: fixture.machine.rawValue, clientID: "fixture-client", store: persistence,
            resolveTarget: { _ in target }, deliver: { _, _ in Issue.record("Replay delivered twice"); return true }, send: { _ in })
        defer { restarted.retire() }
        restarted.apply(rows: [row])
        #expect(restarted.unreadTerminalIDs.isEmpty)
        #expect(owner.state == manualOrder)
        restarted.apply(rows: []) // authoritative remote clear
        #expect(restarted.rows.isEmpty)
        #expect(restarted.unreadTerminalIDs.isEmpty)
    }

    @Test("A retired sync cannot deliver a late event or alter replacement read state")
    func retiredSyncRejectsStaleCallbacks() {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let persistence = CloudNotificationSyncStore(defaults: fixture.defaults)
        var delivered = 0
        let sync = CloudNotificationSync(machineID: "retired", clientID: "fixture-client", store: persistence,
            resolveTarget: { _ in CloudNotificationDeliveryTarget(workspaceID: UUID(), panelID: nil) },
            deliver: { _, _ in delivered += 1; return true }, send: { _ in })
        sync.retire()
        sync.apply(rows: [notification("late", terminal: "term_ws_1")])
        sync.noteRead(notificationIDs: ["late"])
        sync.linkDidConnect()
        #expect(delivered == 0)
        #expect(sync.rows.isEmpty)
        #expect(persistence.load(machineID: "retired") == CloudNotificationSyncState())
    }

    @Test("Notification moves respect pins and machine-scoped terminal identities")
    func notificationRespectsPinsAndMachineIdentity() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let owner = fixture.catalog.sidebarOrganization
        #expect(owner.perform(.pin, id: fixture.folderID("ws_1"), nodes: fixture.nodes()))
        let state = owner.state
        owner.raiseNotification(resource: SurfaceResourceID(machine: .cloud("other-machine"), kind: .terminal, key: "term_ws_2"), nodes: fixture.nodes())
        #expect(owner.state == state)
        owner.raiseNotification(resource: SurfaceResourceID(machine: fixture.machine, kind: .terminal, key: "term_ws_2"), nodes: fixture.nodes())
        let arranged = CloudSidebarOrganizationTree(nodes: fixture.nodes()).arrange(using: owner.state)
        let parent = try #require(CloudSidebarOrganizationTree(nodes: arranged).parent(of: fixture.folderID("ws_1")))
        #expect(parent.children.map(\.id) == [fixture.folderID("ws_1"), fixture.folderID("ws_2")])
        #expect(parent.children[0].isPinned)
        #expect(owner.perform(.pin, id: fixture.folderID("ws_2"), nodes: fixture.nodes()))
        let pinnedOrder = owner.state
        owner.raiseNotification(resource: SurfaceResourceID(machine: fixture.machine, kind: .terminal, key: "term_ws_2"), nodes: fixture.nodes())
        #expect(owner.state == pinnedOrder, "Notifications preserve the manually chosen order of pinned folders")
    }

    private func notification(_ id: String, terminal: String) -> CloudVMNotificationRow {
        CloudVMNotificationRow(id: id, title: "Fixture notification", subtitle: nil, body: "", level: "info",
                               createdAtMs: 1, terminalID: terminal, readBy: [])
    }
}
