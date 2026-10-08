@testable import CmuxiOSSSHCore
import Foundation
import Testing

@Suite struct SSHTmuxPaneOutputRouterTests {
    private let server = SSHTmuxServerEpoch(serverPID: 42, serverStart: 1_793_331_200)!

    @Test func eachPaneRequiresSnapshotAndPreservesIndependentSequence() throws {
        let projection = try #require(Self.projection())
        let identity = try #require(SSHTmuxPaneOutputRouter.Identity(server: server, windowID: "@7"))
        var router = try #require(SSHTmuxPaneOutputRouter(identity: identity, projection: projection))

        #expect(throws: SSHTmuxPaneOutputRouter.Error.awaitingSnapshot) {
            try router.ingest(identity: identity, paneID: "%2", bytes: Data("live".utf8))
        }
        try router.hydrate(identity: identity, paneID: "%2", snapshot: Data(repeating: 65, count: 16_385))
        try router.hydrate(identity: identity, paneID: "%3", snapshot: Data("right".utf8))
        try router.ingest(identity: identity, paneID: "%2", bytes: Data("tail".utf8))

        let left = router.drain(paneID: "%2", maximumBytes: 16_385)
        #expect(left.count == 2)
        #expect(left[0].kind == .snapshot)
        #expect(left[0].sequence == 0)
        #expect(left[1].kind == .live)
        #expect(left[1].sequence == 2)
        #expect(left.map(\.bytes).joined() == Data(repeating: 65, count: 16_385) + Data("tail".utf8))
        let right = router.drain(paneID: "%3")
        #expect(right.map(\.bytes) == [Data("right".utf8)])
        #expect(router.queuedBytes == 0)
    }

    @Test func staleGenerationAndUnknownPaneAreRefused() throws {
        let projection = try #require(Self.projection())
        let identity = try #require(SSHTmuxPaneOutputRouter.Identity(server: server, windowID: "@7"))
        var router = try #require(SSHTmuxPaneOutputRouter(identity: identity, projection: projection))
        let replaced = try #require(SSHTmuxServerEpoch(serverPID: 43, serverStart: server.serverStart))
        let stale = try #require(SSHTmuxPaneOutputRouter.Identity(server: replaced, windowID: "@7"))

        #expect(throws: SSHTmuxPaneOutputRouter.Error.staleServer) {
            try router.hydrate(identity: stale, paneID: "%2", snapshot: Data("old".utf8))
        }
        #expect(throws: SSHTmuxPaneOutputRouter.Error.unknownPane) {
            try router.hydrate(identity: identity, paneID: "%99", snapshot: Data("bad".utf8))
        }
        #expect(router.status(for: "%2")?.phase == .awaitingSnapshot)
    }

    @Test func reconnectClearsQueuedBytesAndRequiresFreshSnapshots() throws {
        let projection = try #require(Self.projection())
        let identity = try #require(SSHTmuxPaneOutputRouter.Identity(server: server, windowID: "@7"))
        var router = try #require(SSHTmuxPaneOutputRouter(identity: identity, projection: projection))
        try router.hydrate(identity: identity, paneID: "%2", snapshot: Data("old".utf8))
        try router.ingest(identity: identity, paneID: "%2", bytes: Data("stale".utf8))
        #expect(router.queuedBytes > 0)

        try router.resetForReconnect(identity: identity)
        #expect(router.queuedBytes == 0)
        #expect(router.status(for: "%2")?.phase == .awaitingSnapshot)
        #expect(throws: SSHTmuxPaneOutputRouter.Error.awaitingSnapshot) {
            try router.ingest(identity: identity, paneID: "%2", bytes: Data("not yet".utf8))
        }
        try router.hydrate(identity: identity, paneID: "%2", snapshot: Data("new".utf8))
        #expect(router.drain(paneID: "%2").map(\.bytes) == [Data("new".utf8)])
    }

    @Test func layoutReconcilePreservesSurvivingParserStateAndDropsRemovedPane() throws {
        let old = try #require(Self.projection())
        let identity = try #require(SSHTmuxPaneOutputRouter.Identity(server: server, windowID: "@7"))
        var router = try #require(SSHTmuxPaneOutputRouter(identity: identity, projection: old))
        try router.hydrate(identity: identity, paneID: "%2", snapshot: Data("left".utf8))
        let nextLayout = try #require(SSHTmuxLayout(validating: Self.wire("80x24,0,0{39x24,0,0,2,40x24,40,0,4}")))
        let next = try #require(SSHTmuxPaneProjection(layout: nextLayout, activePaneID: "%4"))

        let changes = router.reconcile(to: next)
        #expect(changes.map(\.paneID) == ["%3", "%4", "%2"])
        #expect(router.status(for: "%2")?.phase == .live)
        #expect(router.status(for: "%2")?.frame.columns == 39)
        #expect(router.status(for: "%3") == nil)
        #expect(router.status(for: "%4")?.phase == .awaitingSnapshot)
        #expect(throws: SSHTmuxPaneOutputRouter.Error.unknownPane) {
            try router.ingest(identity: identity, paneID: "%3", bytes: Data("stale".utf8))
        }
    }

    @Test func overflowFailsClosedWithoutDroppingSilently() throws {
        let projection = try #require(Self.projection())
        let identity = try #require(SSHTmuxPaneOutputRouter.Identity(server: server, windowID: "@7"))
        var router = try #require(SSHTmuxPaneOutputRouter(identity: identity, projection: projection))
        try router.hydrate(identity: identity, paneID: "%2", snapshot: Data("ok".utf8))
        let oversized = Data(repeating: 88, count: SSHTmuxPaneOutputRouter.maximumQueuedBytesPerPane)
        #expect(throws: SSHTmuxPaneOutputRouter.Error.bufferOverflow) {
            try router.ingest(identity: identity, paneID: "%2", bytes: oversized)
        }
        #expect(router.status(for: "%2")?.phase == .overflowed)
        #expect(router.status(for: "%2")?.queuedBytes == 0)
        #expect(throws: SSHTmuxPaneOutputRouter.Error.streamOverflowed) {
            try router.ingest(identity: identity, paneID: "%2", bytes: Data("later".utf8))
        }
    }

    private static func projection() -> SSHTmuxPaneProjection? {
        guard let layout = SSHTmuxLayout(validating: wire("80x24,0,0{39x24,0,0,2,40x24,40,0,3}")) else { return nil }
        return SSHTmuxPaneProjection(layout: layout, activePaneID: "%2")
    }

    private static func wire(_ body: String) -> String {
        var checksum: UInt16 = 0
        for byte in body.utf8 {
            checksum = (checksum >> 1) | ((checksum & 1) << 15)
            checksum &+= UInt16(byte)
        }
        return String(format: "%04x,", checksum) + body
    }
}
