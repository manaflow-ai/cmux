import Foundation
import CmuxSettings
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

    @Test("One terminal viewed in two folders does not reverse them on each notification")
    func multiWorkspaceNotificationKeepsRelativeOrder() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let snapshot = fixture.snapshot()
        var terminal = snapshot.resources[0]
        let secondView = try #require(snapshot.resources[1].remoteViews?.first)
        terminal.remoteViews?.append(secondView)
        let shared = SurfaceCatalogSnapshot(machines: snapshot.machines, resources: [terminal], projections: [])
        let owner = fixture.catalog.sidebarOrganization
        for _ in 0..<3 {
            let tree = CloudSidebarOrganizationTree(nodes: CloudTreeNodeBuilder.nodes(
                machines: [], snapshot: shared, localWorkspaces: [], includeLocalMachine: false
            )).arrange(using: owner.state)
            owner.raiseNotification(resource: terminal.id, nodes: tree)
            let arranged = CloudSidebarOrganizationTree(nodes: tree).arrange(using: owner.state)
            let parent = try #require(CloudSidebarOrganizationTree(nodes: arranged).parent(of: fixture.folderID("ws_1")))
            #expect(parent.children.map(\.id) == [fixture.folderID("ws_1"), fixture.folderID("ws_2")])
        }
    }

    @Test("Notification bursts coalesce once per machine in newest-terminal order")
    func notificationsCoalesceByMachine() {
        let a = SurfaceResourceID(machine: .cloud("one"), kind: .terminal, key: "a")
        let b = SurfaceResourceID(machine: .cloud("one"), kind: .terminal, key: "b")
        let c = SurfaceResourceID(machine: .cloud("two"), kind: .terminal, key: "c")
        var calls: [(SurfaceMachineID, [SurfaceResourceID])] = []
        let coordinator = CloudSidebarNotificationCoordinator { calls.append(($0, $1)) }
        for resource in [a, b, c, a, c] { coordinator.enqueue(resource) }
        #expect(calls.isEmpty)
        coordinator.flush()
        #expect(calls.count == 2)
        #expect(calls.first?.0 == a.machine)
        #expect(calls.first?.1 == [b, a])
        #expect(calls.last?.1 == [c])
        coordinator.flush()
        #expect(calls.count == 2)
    }

    @Test("Queued notifications reconcile resource liveness before changing order")
    func queuedNotificationCannotRaiseDeletedResource() {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.catalog.raiseCloudSidebarNotification(machineID: fixture.machine.rawValue, terminalID: "term_ws_2")
        _ = fixture.catalog.replaceResources([fixture.snapshot().resources[0]], on: fixture.machine, from: fixture.provider)
        fixture.catalog.sidebarNotifications.flush()
        #expect(fixture.catalog.sidebarOrganization.state.groups.isEmpty)
        #expect(fixture.catalog.sidebarNodes(on: fixture.machine).allSatisfy { $0.machine == fixture.machine })
    }

    @Test("Sign-out retains pins but confirmed machine deletion forgets them durably")
    func deletionAndDisconnectionHaveDifferentPersistence() {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let owner = fixture.catalog.sidebarOrganization
        #expect(fixture.catalog.organizeSidebar(.pin, nodeID: fixture.folderID("ws_2")))
        let pinned = owner.state
        fixture.catalog.unregister(machine: fixture.machine)
        #expect(owner.state == pinned)
        #expect(CloudSidebarOrganizationStore(defaults: fixture.defaults).state == pinned)
        fixture.catalog.register(fixture.provider)
        _ = fixture.catalog.replaceResources(fixture.snapshot().resources, on: fixture.machine, from: fixture.provider)
        fixture.catalog.raiseCloudSidebarNotification(machineID: fixture.machine.rawValue, terminalID: "term_ws_2")
        fixture.catalog.removeCloudMachine(fixture.machine)
        fixture.catalog.sidebarNotifications.flush()
        #expect(owner.state.groups.isEmpty)
        #expect(CloudSidebarOrganizationStore(defaults: fixture.defaults).state.groups.isEmpty)
        #expect(fixture.catalog.machines[fixture.machine] == nil)
    }

    @Test("Completion raises folders while preserving all terminal orders")
    func completionNeverReordersTerminals() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let snapshot = fixture.snapshot()
        var extra = snapshot.resources[1]
        extra.id.key = "term_extra"
        extra.remoteViews?[0].tabID = "tab_extra"
        let extended = SurfaceCatalogSnapshot(machines: snapshot.machines,
            resources: snapshot.resources + [extra], projections: [])
        let nodes = CloudTreeNodeBuilder.nodes(machines: [], snapshot: extended,
            localWorkspaces: [], includeLocalMachine: false)
        let owner = fixture.catalog.sidebarOrganization
        let flat = CloudTreeNodeBuilder.flattened(nodes)
        let folder = try #require(flat.first { $0.id == fixture.folderID("ws_2") })
        let last = try #require(folder.children.last)
        #expect(owner.perform(.up, id: last.id, nodes: nodes))
        let before = CloudSidebarOrganizationTree(nodes: nodes).arrange(using: owner.state)
        let terminalOrders = Dictionary(uniqueKeysWithValues: CloudTreeNodeBuilder.flattened(before)
            .filter { $0.children.contains { if case .terminal = $0.kind { return true }; return false } }
            .map { ($0.id, $0.children.map(\.id)) })
        let target = try #require(folder.children.last?.dragResource?.id)
        owner.raiseNotification(resource: target, nodes: before)
        let after = CloudSidebarOrganizationTree(nodes: nodes).arrange(using: owner.state)
        let group = try #require(CloudSidebarOrganizationTree(nodes: after).parent(of: folder.id))
        #expect(group.children.first?.id == folder.id)
        for row in CloudTreeNodeBuilder.flattened(after) {
            if let expected = terminalOrders[row.id] { #expect(row.children.map(\.id) == expected) }
        }
        #expect(CloudSidebarOrganizationStore(defaults: fixture.defaults).state == owner.state)
    }

    @Test("Disabled notification ordering leaves both sidebar orders unchanged", arguments: [false, true])
    func sharedSettingGatesBothSidebars(enabled: Bool) {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.defaults.set(enabled, forKey: SettingCatalog().app.reorderOnNotification.userDefaultsKey)
        var localMoves = 0
        let initial = fixture.catalog.sidebarOrganization.state
        var effects = TerminalNotificationPolicyEffects()
        effects.applySidebarOrdering(defaults: fixture.defaults) {
            localMoves += 1
            fixture.catalog.sidebarOrganization.raiseNotification(resource: .init(machine: fixture.machine,
                kind: .terminal, key: "term_ws_2"), nodes: fixture.nodes())
        }
        #expect(localMoves == (enabled ? 1 : 0))
        #expect((fixture.catalog.sidebarOrganization.state != initial) == enabled)
        let admitted = fixture.catalog.sidebarOrganization.state
        effects.reorderWorkspace = false
        effects.applySidebarOrdering(defaults: fixture.defaults) { Issue.record("Suppressed event reordered sidebars") }
        #expect(fixture.catalog.sidebarOrganization.state == admitted)
    }

    private func notification(_ id: String, terminal: String) -> CloudVMNotificationRow {
        CloudVMNotificationRow(id: id, title: "Fixture notification", subtitle: nil, body: "", level: "info",
                               createdAtMs: 1, terminalID: terminal, readBy: [])
    }
}
