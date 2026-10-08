@testable import CmuxiOSSSHCore
import Foundation
import Testing

@Suite struct SSHTmuxPaneCompositionTests {
    private let splitBody = "80x24,0,0{39x24,0,0,2,40x24,40,0,3}"

    @Test func inputRoutingReturnsPaneLocalCoordinatesAndRejectsDividers() throws {
        let layout = try #require(SSHTmuxLayout(validating: Self.wire(splitBody)))
        let composition = SSHTmuxPaneComposition(
            projection: try #require(SSHTmuxPaneProjection(layout: layout, activePaneID: "%3")))

        let left = try #require(composition.inputTarget(atColumn: 0, row: 0))
        #expect(left.paneID == "%2")
        #expect(left.column == 0)
        #expect(left.row == 0)
        let right = try #require(composition.inputTarget(atColumn: 40, row: 23))
        #expect(right.paneID == "%3")
        #expect(right.column == 0)
        #expect(right.row == 23)
        #expect(composition.inputTarget(atColumn: 39, row: 0) == nil) // tmux divider
        #expect(composition.inputTarget(atColumn: 80, row: 0) == nil) // outside root
        #expect(composition.inputTarget(atColumn: 0, row: -1) == nil)
    }

    @Test func reconcilePreservesPaneIdentityAndReportsStableOperations() throws {
        let oldLayout = try #require(SSHTmuxLayout(validating: Self.wire(splitBody)))
        var composition = SSHTmuxPaneComposition(
            projection: try #require(SSHTmuxPaneProjection(layout: oldLayout, activePaneID: "%2")))

        let nextBody = "80x24,0,0{39x24,0,0,2,40x24,40,0[40x11,40,0,3,40x12,40,12,4]}"
        let nextLayout = try #require(SSHTmuxLayout(validating: Self.wire(nextBody)))
        let next = try #require(SSHTmuxPaneProjection(layout: nextLayout, activePaneID: "%4"))
        let changes = composition.reconcile(to: next)

        #expect(changes.map(\.paneID) == ["%4", "%2", "%3"])
        guard case .added(let added) = changes[0] else {
            Issue.record("expected the new pane first")
            return
        }
        #expect(added.id == "%4")
        guard case .updated(let activeUpdate) = changes[1] else {
            Issue.record("expected active-state update for pane %2")
            return
        }
        #expect(activeUpdate.previous.isActive)
        #expect(!activeUpdate.current.isActive)
        #expect(!activeUpdate.frameChanged)
        guard case .updated(let resized) = changes[2] else {
            Issue.record("expected frame update for pane %3")
            return
        }
        #expect(resized.frameChanged)
        #expect(resized.previous.id == resized.current.id)
        #expect(composition.projection == next)
    }

    @Test func reconcileEmitsRemovalsBeforeAdditionsAndNoopForEquivalentProjection() throws {
        let oldLayout = try #require(SSHTmuxLayout(validating: Self.wire(splitBody)))
        var composition = SSHTmuxPaneComposition(
            projection: try #require(SSHTmuxPaneProjection(layout: oldLayout, activePaneID: "%2")))
        let singleLayout = try #require(SSHTmuxLayout(validating: Self.wire("80x24,0,0,2")))
        let single = try #require(SSHTmuxPaneProjection(layout: singleLayout, activePaneID: "%2"))
        let removal = composition.reconcile(to: single)

        #expect(removal.count == 1)
        guard case .removed(let removed) = removal[0] else {
            Issue.record("expected pane %3 removal")
            return
        }
        #expect(removed.id == "%3")
        #expect(composition.reconcile(to: single).isEmpty)
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
