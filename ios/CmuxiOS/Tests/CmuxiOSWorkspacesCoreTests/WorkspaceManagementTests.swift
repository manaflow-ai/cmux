import CmuxiOSFeatureKit
import CmuxMobileWire
@testable import CmuxiOSWorkspacesCore
import Foundation
import Testing

/// E3 (e3-workspaces.md section 5): groups, reorder, customize on the phone.
@Suite struct WorkspaceManagementTests {
    let host = HostID("h_mac1")
    static let app = WorkspaceGroup(id: "grp_app", name: "App", order: 0)
    static let ops = WorkspaceGroup(id: "grp_ops", name: "Ops", order: 1)

    func summary(_ id: String, order: Int, group: WorkspaceGroup? = nil, pinned: Bool = false) -> WorkspaceSummary {
        WorkspaceSummary(id: id, hostID: host, title: id, status: .idle, paneCount: 1, isPinned: pinned, group: group, order: order)
    }

    /// a(app) b(app) c d, groups app and empty ops.
    var hostValue: HostWorkspaces {
        HostWorkspaces(hostID: host, hostName: "Mac", isReachable: true, workspaces: [
            summary("ws_a", order: 0, group: Self.app), summary("ws_b", order: 1, group: Self.app),
            summary("ws_c", order: 2), summary("ws_d", order: 3),
        ], capabilities: .all, groups: [Self.app, Self.ops])
    }

    func ids(_ arrangement: WorkspaceArrangement) -> [String] {
        arrangement.workspaces.sorted { $0.order < $1.order }.map(\.id)
    }

    // MARK: Arrangement (the owner's rule, shared by overlay and mock)

    @Test func moveFilesAndRenumbers() {
        var a = WorkspaceArrangement(workspaces: hostValue.workspaces, groups: hostValue.groups)
        a.move("ws_d", to: .group("grp_app"), index: 1)
        #expect(ids(a) == ["ws_a", "ws_d", "ws_b", "ws_c"])
        #expect(a.workspaces.first { $0.id == "ws_d" }?.group?.id == "grp_app")
        a.move("ws_a", to: .ungrouped, index: 9)
        #expect(ids(a) == ["ws_d", "ws_b", "ws_c", "ws_a"])
        #expect(a.workspaces.first { $0.id == "ws_a" }?.group == nil)
        // An empty group keeps the workspace's place.
        a.move("ws_c", to: .group("grp_ops"), index: 0)
        #expect(ids(a) == ["ws_d", "ws_b", "ws_c", "ws_a"])
        #expect(a.workspaces.first { $0.id == "ws_c" }?.group == Self.ops)
        a.move("ws_zz", to: .keep, index: 0)
        #expect(ids(a) == ["ws_d", "ws_b", "ws_c", "ws_a"])
    }

    @Test func renameGroupAndCustomize() {
        var a = WorkspaceArrangement(workspaces: hostValue.workspaces, groups: hostValue.groups)
        a.renameGroup("grp_app", to: "Apps")
        #expect(a.groups.first?.name == "Apps")
        #expect(a.workspaces.filter { $0.group?.id == "grp_app" }.allSatisfy { $0.group?.name == "Apps" })
        a.customize("ws_c", color: .set("blue"), icon: .set("star"))
        a.customize("ws_c", color: .unchanged, icon: .clear)
        #expect(a.workspaces.first { $0.id == "ws_c" }?.color == "blue")
        #expect(a.workspaces.first { $0.id == "ws_c" }?.icon == nil)
    }

    // MARK: Intent log

    @Test func overlayShowsPendingArrangementUntilSettled() {
        var log = WorkspaceIntentLog()
        log.append(.move(workspaceID: "ws_d", group: .group("grp_app"), index: 0), key: IntentKey(rawValue: "move-key-01"))
        log.append(.renameGroup(hostID: host, groupID: "grp_ops", name: "Infra"), key: IntentKey(rawValue: "rename-key-1"))
        log.append(.customize(workspaceID: "ws_c", color: .set("red"), icon: .unchanged), key: IntentKey(rawValue: "custom-key-1"))
        let visible = log.overlay(WorkspaceArrangement(workspaces: hostValue.workspaces, groups: hostValue.groups))
        #expect(ids(visible) == ["ws_d", "ws_a", "ws_b", "ws_c"])
        #expect(visible.groups.map(\.name) == ["App", "Infra"])
        #expect(visible.workspaces.first { $0.id == "ws_c" }?.color == "red")
        log.remove(IntentKey(rawValue: "move-key-01"))
        let after = log.overlay(WorkspaceArrangement(workspaces: hostValue.workspaces, groups: hostValue.groups))
        #expect(ids(after) == ["ws_a", "ws_b", "ws_c", "ws_d"])
    }

    // MARK: Wire

    @Test func opsEncodeNullAsUngroupAndAbsentAsKeep() throws {
        let encoder = WorkspaceOpEncoder(hostID: host)
        let keep = try encoder.frame(for: .move(workspaceID: "ws_a", group: .keep, index: 2), key: IntentKey())
        #expect(keep.op == "workspace.move")
        #expect(keep.params == .object(["workspace": "ws_a", "index": .int(2)]))
        let ungroup = try encoder.frame(for: .move(workspaceID: "ws_a", group: .ungrouped, index: 0), key: IntentKey())
        #expect(ungroup.params == .object(["workspace": "ws_a", "group": .null, "index": .int(0)]))
        let into = try encoder.frame(for: .move(workspaceID: "ws_a", group: .group("grp_ops"), index: 0), key: IntentKey())
        #expect(into.params["group"] == "grp_ops")
        let rename = try encoder.frame(for: .renameGroup(hostID: host, groupID: "grp_app", name: "Apps"), key: IntentKey())
        #expect(rename.op == "workspace.group.rename")
        #expect(rename.params == .object(["group": "grp_app", "name": "Apps"]))
        let look = try encoder.frame(for: .customize(workspaceID: "ws_a", color: .set("blue"), icon: .clear), key: IntentKey())
        #expect(look.op == "workspace.customize")
        #expect(look.params == .object(["workspace": "ws_a", "color": "blue", "icon": .null]))
        for name in ["workspace.move", "workspace.group.rename", "workspace.customize"] {
            #expect(MobileCatalog.v1.message(named: name)?.kind == .op)
        }
    }

    @Test func capsGateTheNewIntents() {
        let none = WorkspaceCapabilities(negotiated: [])
        #expect(!none.contains(.move) && !none.contains(.renameGroup) && !none.contains(.customize))
        let all = WorkspaceCapabilities(negotiated: ["workspace.move", "workspace.group.rename", "workspace.customize"])
        #expect(all.contains(.move) && all.contains(.renameGroup) && all.contains(.customize))
    }

    @Test func mirrorTakesGroupsFromSnapshotAndEvents() throws {
        let wire = WireFrames(host: "h_mac1")
        var mirror = HostWorkspaceMirror()
        var snapshotState: [String: JSONValue] = [
            "host": "h_mac1",
            "workspaces": .array([WireFrames.simple("ws_a", name: "a", order: 0)]),
            "groups": .array([.object(["id": "grp_app", "name": "App", "order": 0])]),
        ]
        try mirror.apply(SnapshotFrame(stream: wire.stream, seq: 5, state: .object(snapshotState), decided: []))
        #expect(mirror.confirmedGroups == [Self.app])
        let groups: JSONValue = .array([.object(["id": "grp_ops", "name": "Ops", "order": 1]),
                                        .object(["id": "grp_app", "name": "App", "order": 0])])
        #expect(mirror.apply(wire.event(seq: 6, "workspace.groups.set", ["groups": groups])) == .applied)
        #expect(mirror.confirmedGroups.map(\.id) == ["grp_app", "grp_ops"])
        // An older Mac without `groups`: groups come from the members.
        snapshotState["groups"] = nil
        snapshotState["workspaces"] = .array([WireFrames.workspace("ws_b", name: "b", order: 0, group: ("grp_x", "X"), panes: [])])
        try mirror.apply(SnapshotFrame(stream: wire.stream, seq: 9, state: .object(snapshotState), decided: []))
        #expect(mirror.confirmedGroups == [WorkspaceGroup(id: "grp_x", name: "X")])
    }

    // MARK: Reorder

    @Test func reorderResolvesAgainstTheFullOrder() {
        var value = hostValue
        // ws_b pinned: hidden from the app section, still a member at the owner.
        value.workspaces[1].isPinned = true
        let reorder = WorkspaceReorder(host: value)
        #expect(!reorder.canMove("ws_b"))
        // d dropped at the end of app: after a and b (index 2 among a, b).
        #expect(reorder.intent(moving: "ws_d", to: .group("grp_app"), before: nil)
            == .move(workspaceID: "ws_d", group: .group("grp_app"), index: 2))
        // d dropped before a in app.
        #expect(reorder.intent(moving: "ws_d", to: .group("grp_app"), before: "ws_a")
            == .move(workspaceID: "ws_d", group: .group("grp_app"), index: 0))
        // c dropped after d in the ungrouped section: same section, keep.
        #expect(reorder.intent(moving: "ws_c", to: .ungrouped, before: nil)
            == .move(workspaceID: "ws_c", group: .keep, index: 1))
        // c dropped where it is: nothing to send.
        #expect(reorder.intent(moving: "ws_c", to: .ungrouped, before: "ws_d") == nil)
        // a into the empty ops group, then out to ungrouped.
        #expect(reorder.intent(moving: "ws_a", to: .group("grp_ops"), before: nil)
            == .move(workspaceID: "ws_a", group: .group("grp_ops"), index: 0))
        #expect(reorder.intent(moving: "ws_a", to: .ungrouped, before: "ws_c")
            == .move(workspaceID: "ws_a", group: .ungrouped, index: 0))
        #expect(reorder.intent(moving: "ws_a", to: .group("grp_nope"), before: nil) == nil)
    }

    @Test func reorderNeedsTheCapAndAReachableHost() {
        var value = hostValue
        value.capabilities = [.rename]
        #expect(WorkspaceReorder(host: value).intent(moving: "ws_c", to: .group("grp_app"), before: nil) == nil)
        value.capabilities = .all
        value.isReachable = false
        #expect(!WorkspaceReorder(host: value).canMove("ws_c"))
        #expect(WorkspaceReorder.isAvailable(WorkspaceViewPreferences()))
        #expect(!WorkspaceReorder.isAvailable(WorkspaceViewPreferences(sort: .name)))
        #expect(!WorkspaceReorder.isAvailable(WorkspaceViewPreferences(filter: .unread)))
        #expect(!WorkspaceReorder.isAvailable(WorkspaceViewPreferences(grouping: .flat)))
    }

    // MARK: List

    @Test func collapsedGroupsKeepTheirHeaderAndCount() {
        var preferences = WorkspaceViewPreferences()
        preferences.toggleCollapsed(host: host, group: "grp_app")
        let list = WorkspaceListBuilder(preferences: preferences).snapshot(for: [hostValue])
        let app = list.sections.first { $0.kind == .group(id: "grp_app", name: "App") }
        #expect(app?.isCollapsed == true)
        #expect(app?.rows.isEmpty == true)
        #expect(app?.memberCount == 2)
        #expect(app?.capabilities.contains(.renameGroup) == true)
        #expect(list.emptyState == nil)
        preferences.toggleCollapsed(host: host, group: "grp_app")
        #expect(preferences.collapsedGroups.isEmpty)
    }

    @Test func editingListsEmptyDropTargets() {
        let builder = WorkspaceListBuilder(preferences: WorkspaceViewPreferences())
        #expect(builder.snapshot(for: [hostValue]).sections.map(\.id) == ["host:h_mac1/group:grp_app", "host:h_mac1/all"])
        let editing = builder.snapshot(for: [hostValue], editing: true)
        #expect(editing.sections.map(\.id) == ["host:h_mac1/group:grp_app", "host:h_mac1/group:grp_ops", "host:h_mac1/all"])
        #expect(editing.sections[1].kind.dropPlacement == .group("grp_ops"))
        #expect(editing.sections[2].kind.dropPlacement == .ungrouped)
        #expect(editing.rows.first { $0.workspaceID == "ws_a" }?.groupID == "grp_app")
    }

    @Test func rowsCarryTheLook() {
        var value = hostValue
        value.workspaces[2].color = "blue"
        value.workspaces[2].icon = "star"
        let row = WorkspaceListBuilder(preferences: WorkspaceViewPreferences()).snapshot(for: [value]).rows.first { $0.workspaceID == "ws_c" }
        #expect(row?.color == "blue")
        #expect(row?.icon == "star")
    }

    @Test func oldPreferencesStillDecode() throws {
        let old = #"{"filter":"all","sort":"ownerOrder","grouping":"byMachine","hiddenHosts":[],"hostOrder":["a"]}"#
        let decoded = try JSONDecoder().decode(WorkspaceViewPreferences.self, from: Data(old.utf8))
        #expect(decoded.hostOrder == [HostID("a")])
        #expect(decoded.collapsedGroups.isEmpty)
        var round = decoded
        round.collapsedGroups = ["a/g"]
        let again = try JSONDecoder().decode(WorkspaceViewPreferences.self, from: JSONEncoder().encode(round))
        #expect(again == round)
    }

    // MARK: Source end to end

    @Test func sourceOverlaysAMoveUntilTheEcho() async throws {
        let wire = WireFrames(host: "h_mac1")
        let factory = FakeChannelFactory([host])
        let source = ControlPlaneWorkspaceSource(
            directory: StaticHostDirectory([WorkspaceHostDescriptor(id: host, name: "Mac")]), channels: factory)
        var waiter = SnapshotWaiter(await source.updates())
        let channel = factory[host]
        await channel.waitForSubscriber()
        await channel.send(.live(path: nil, caps: ["workspace.move"]))
        await channel.send(.snapshot(wire.snapshot(seq: 1, [
            WireFrames.simple("ws_a", name: "a", order: 0), WireFrames.simple("ws_b", name: "b", order: 1),
        ])))
        _ = await waiter.until { $0.value.first?.workspaces.count == 2 }
        #expect(await source.current.value.first?.capabilities.contains(.move) == true)
        await channel.setAnswer { op in
            .applied(ResultFrame(tx: "tx_1", idempotencyKey: op.idempotencyKey, value: .object([:]), revision: "2", replayed: false))
        }
        let receipt = try await source.perform(.move(workspaceID: "ws_b", group: .keep, index: 0), key: IntentKey(rawValue: "move-key-01"))
        guard case .committed = receipt else { Issue.record("not committed: \(receipt)"); return }
        let pending = await source.current.value.first?.workspaces.sorted { $0.order < $1.order }.map(\.id)
        #expect(pending == ["ws_b", "ws_a"])
        #expect(await channel.submitted.last?.op == "workspace.move")
        // The owner's echo at seq 2 settles it with the same order.
        await channel.send(.event(wire.event(seq: 2, "workspace.upsert", [
            "workspace": WireFrames.simple("ws_b", name: "b", order: -1),
        ])))
        let settled = await waiter.until { $0.value.first?.workspaces.first?.id == "ws_b" && $0.value.first?.workspaces.first?.order == -1 }
        #expect(settled?.value.first?.workspaces.map(\.id) == ["ws_b", "ws_a"])
    }

    @Test func sshHostsOfferNoIntents() async {
        var session = WorkspaceHostSession(descriptor: WorkspaceHostDescriptor(id: HostID("ssh_x"), name: "box", kind: .ssh))
        session.state = .live(path: "ssh", caps: ["workspace.move", "workspace.close"])
        #expect(session.value.capabilities.isEmpty)
        #expect(session.value.isReachable)
    }
}
