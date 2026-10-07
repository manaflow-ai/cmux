import CmuxiOSFeatureKit
import CmuxMobileWire
import CmuxiOSWorkspacesCore
import Testing

@Suite struct IntentLogTests {
    let host = HostID("h_mac1")
    var confirmed: [WorkspaceSummary] {
        [
            WorkspaceSummary(id: "ws_a", hostID: host, title: "alpha", status: .running, paneCount: 1, unreadCount: 2,
                             panes: [WorkspacePane(id: "pane_a", surfaces: [
                                WorkspaceSurface(id: "tab_a", kind: .terminal, title: "zsh", unreadCount: 2),
                             ])]),
            WorkspaceSummary(id: "ws_b", hostID: host, title: "beta", status: .idle, paneCount: 1),
        ]
    }

    @Test func overlayAppliesInOrder() {
        var log = WorkspaceIntentLog()
        log.append(.rename(workspaceID: "ws_a", title: "one"), key: IntentKey(rawValue: "k1-aaaaaa"))
        log.append(.rename(workspaceID: "ws_a", title: "two"), key: IntentKey(rawValue: "k2-aaaaaa"))
        log.append(.markRead(workspaceID: "ws_a"), key: IntentKey(rawValue: "k3-aaaaaa"))
        log.append(.close(workspaceID: "ws_b"), key: IntentKey(rawValue: "k4-aaaaaa"))
        let visible = log.overlay(confirmed)
        #expect(visible.map(\.id) == ["ws_a"])
        #expect(visible[0].title == "two")
        #expect(visible[0].unreadCount == 0)
        #expect(visible[0].panes[0].surfaces[0].unreadCount == 0)
    }

    @Test func duplicateKeyIsOneEntry() {
        var log = WorkspaceIntentLog()
        let key = IntentKey(rawValue: "same-key-1")
        log.append(.close(workspaceID: "ws_b"), key: key)
        log.append(.close(workspaceID: "ws_b"), key: key)
        #expect(log.entries.count == 1)
    }

    @Test func committedLeavesWhenTheMirrorReachesTheSeq() {
        var log = WorkspaceIntentLog()
        let key = IntentKey(rawValue: "commit-key")
        log.append(.rename(workspaceID: "ws_a", title: "x"), key: key)
        log.committed(key, at: 12, mirrorSeq: 10)
        #expect(log.entries.first?.committedAt == 12)
        log.settle(through: 11)
        #expect(!log.isEmpty)
        log.settle(through: 12)
        #expect(log.isEmpty)
    }

    @Test func committedBehindTheMirrorLeavesAtOnce() {
        var log = WorkspaceIntentLog()
        let key = IntentKey(rawValue: "late-result")
        log.append(.close(workspaceID: "ws_b"), key: key)
        log.committed(key, at: 9, mirrorSeq: 10)
        #expect(log.isEmpty)
    }

    @Test func snapshotDecidedKeysSettle() {
        var log = WorkspaceIntentLog()
        log.append(.close(workspaceID: "ws_b"), key: IntentKey(rawValue: "decided-1"))
        log.append(.rename(workspaceID: "ws_a", title: "y"), key: IntentKey(rawValue: "pending-2"))
        log.settle(decided: [DecidedKey(idempotencyKey: "decided-1", ok: true, sequence: 5)], snapshotSeq: 6)
        #expect(log.entries.map(\.key.rawValue) == ["pending-2"])
    }

    @Test func rejectRemoves() {
        var log = WorkspaceIntentLog()
        let key = IntentKey(rawValue: "reject-me")
        log.append(.close(workspaceID: "ws_b"), key: key)
        log.remove(key)
        #expect(log.overlay(confirmed).count == 2)
    }
}
