import CmuxiOSFeatureKit
import CmuxMobileWire
@testable import CmuxiOSWorkspacesCore
import Foundation
import Testing

@Suite struct MirrorTests {
    let wire = WireFrames(host: "h_mac1")
    let host = HostID("h_mac1")

    func seeded() throws -> HostWorkspaceMirror {
        var mirror = HostWorkspaceMirror()
        try mirror.apply(wire.snapshot(seq: 10, [
            WireFrames.simple("ws_b", name: "beta", order: 1),
            WireFrames.simple("ws_a", name: "alpha", order: 0, status: "running", unread: 2),
        ]))
        return mirror
    }

    @Test func snapshotSortsByOwnerOrderAndRollsUp() throws {
        let mirror = try seeded()
        let rows = mirror.summaries(hostID: host)
        #expect(rows.map(\.id) == ["ws_a", "ws_b"])
        #expect(rows[0].status == .running)
        #expect(rows[0].unreadCount == 2)
        #expect(rows[0].panes.first?.surfaces.first?.terminalID == "term_a")
        #expect(mirror.seq == 10)
    }

    @Test func eventsApplyOnlyWhenContiguous() throws {
        var mirror = try seeded()
        #expect(mirror.apply(wire.event(seq: 11, "workspace.remove", ["workspace": .string("ws_b")])) == .applied)
        #expect(mirror.summaries(hostID: host).map(\.id) == ["ws_a"])
        #expect(mirror.apply(wire.event(seq: 11, "workspace.remove", ["workspace": .string("ws_a")])) == .duplicate)
        #expect(mirror.summaries(hostID: host).count == 1)
        #expect(mirror.apply(wire.event(seq: 13, "workspace.remove", ["workspace": .string("ws_a")])) == .gap)
        #expect(mirror.needsSnapshot)
        // After a gap even the next contiguous seq waits for the snapshot.
        #expect(mirror.apply(wire.event(seq: 12, "workspace.remove", ["workspace": .string("ws_a")])) == .gap)
        try mirror.apply(wire.snapshot(seq: 20, [WireFrames.simple("ws_c", name: "gamma", order: 0)]))
        #expect(!mirror.needsSnapshot)
        #expect(mirror.summaries(hostID: host).map(\.id) == ["ws_c"])
    }

    @Test func duplicateIdsInASnapshotKeepTheFirst() throws {
        var mirror = HostWorkspaceMirror()
        try mirror.apply(wire.snapshot(seq: 1, [
            WireFrames.simple("ws_a", name: "first", order: 0),
            WireFrames.simple("ws_a", name: "second", order: 1),
        ]))
        #expect(mirror.summaries(hostID: host).map(\.title) == ["first"])
    }

    @Test func newEpochDropsTheMirror() throws {
        var mirror = HostWorkspaceMirror()
        var first = wire.snapshot(seq: 1_000, [WireFrames.simple("ws_a", name: "alpha", order: 0)])
        first.epoch = "ep_1000_aaaa"
        try mirror.apply(first)
        var same = wire.event(seq: 1_001, "workspace.remove", ["workspace": .string("ws_a")])
        same.epoch = "ep_1000_aaaa"
        var restarted = wire.event(seq: 1_001, "workspace.upsert", ["workspace": WireFrames.simple("ws_z", name: "z", order: 0)])
        restarted.epoch = "ep_2000_bbbb"
        // Same seq, other epoch: not a duplicate and not applicable.
        #expect(mirror.apply(restarted) == .gap)
        #expect(mirror.summaries(hostID: host).isEmpty)
        #expect(!mirror.hasSnapshot)
        #expect(mirror.apply(same) == .awaitingSnapshot)
        var fresh = wire.snapshot(seq: 2_005, [WireFrames.simple("ws_z", name: "z", order: 0)])
        fresh.epoch = "ep_2000_bbbb"
        try mirror.apply(fresh)
        #expect(mirror.epoch == "ep_2000_bbbb")
        #expect(mirror.summaries(hostID: host).map(\.id) == ["ws_z"])
        // Events without an epoch (a relay that strips it) still apply by seq.
        #expect(mirror.apply(wire.event(seq: 2_006, "workspace.remove", ["workspace": .string("ws_z")])) == .applied)
    }

    @Test func eventsBeforeSnapshotWait() {
        var mirror = HostWorkspaceMirror()
        #expect(mirror.apply(wire.event(seq: 1, "workspace.remove", ["workspace": .string("ws_a")])) == .awaitingSnapshot)
    }

    @Test func tabEventsUpdateStatusUnreadAndPreview() throws {
        var mirror = try seeded()
        #expect(mirror.apply(wire.event(seq: 11, "workspace.tab.upsert", [
            "workspace": .string("ws_b"), "pane": .string("pane_b"), "index": .int(0),
            "tab": WireFrames.tab("tab_x", kind: "agent", title: "Fix tests", status: "needs_input", unread: 1),
        ])) == .applied)
        #expect(mirror.apply(wire.event(seq: 12, "workspace.preview.set", [
            "tab": .string("tab_x"), "preview": .string("Approve?"),
        ])) == .applied)
        var beta = try #require(mirror.summaries(hostID: host).first { $0.id == "ws_b" })
        #expect(beta.status == .waitingForInput)
        #expect(beta.preview == "Approve?")
        #expect(beta.panes[0].surfaces.map(\.id) == ["tab_x", "tab_b"])
        #expect(mirror.apply(wire.event(seq: 13, "workspace.status.set", [
            "tab": .string("tab_x"), "status": .string("error"), "unread": .int(0),
        ])) == .applied)
        beta = try #require(mirror.summaries(hostID: host).first { $0.id == "ws_b" })
        #expect(beta.status == .failed)
        #expect(beta.unreadCount == 0)
        #expect(mirror.apply(wire.event(seq: 14, "workspace.tab.remove", ["tab": .string("tab_x")])) == .applied)
        #expect(mirror.apply(wire.event(seq: 15, "workspace.tab.remove", ["tab": .string("tab_b")])) == .applied)
        beta = try #require(mirror.summaries(hostID: host).first { $0.id == "ws_b" })
        #expect(beta.panes.isEmpty)
    }

    @Test func tabUpsertIntoUnknownWorkspaceIsAGap() throws {
        var mirror = try seeded()
        let result = mirror.apply(wire.event(seq: 11, "workspace.tab.upsert", [
            "workspace": .string("ws_zz"), "pane": .string("pane_z"), "index": .int(0), "tab": WireFrames.tab("tab_z"),
        ]))
        #expect(result == .gap)
        #expect(mirror.seq == 10)
    }

    @Test func unknownOpKeepsTheSequence() throws {
        var mirror = try seeded()
        #expect(mirror.apply(wire.event(seq: 11, "workspace.future.thing", [:])) == .applied)
        #expect(mirror.seq == 11)
    }

    @Test func upsertReplacesAndReorders() throws {
        var mirror = try seeded()
        #expect(mirror.apply(wire.event(seq: 11, "workspace.upsert", [
            "workspace": WireFrames.simple("ws_b", name: "beta 2", order: -1),
        ])) == .applied)
        #expect(mirror.summaries(hostID: host).map(\.title) == ["beta 2", "alpha"])
    }
}
