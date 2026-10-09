@testable import CmuxiOSSSHCore
import Foundation
import Testing

@Suite struct SSHTmuxPaneProjectionTests {
    private let mixedBody = "121x40,0,0{60x40,0,0,7,60x40,61,0[60x19,61,0,9,60x20,61,20,11]}"

    @Test func projectionKeepsHostOrderFramesAndActiveState() throws {
        let layout = try #require(SSHTmuxLayout(validating: Self.wire(mixedBody)))
        let projection = try #require(SSHTmuxPaneProjection(layout: layout, activePaneID: "%11"))

        #expect(projection.frame.columns == 121)
        #expect(projection.frame.rows == 40)
        #expect(projection.activePaneID == "%11")
        #expect(projection.panes.map(\.id) == ["%7", "%9", "%11"])
        #expect(projection.panes.map(\.order) == [0, 1, 2])
        #expect(projection.panes.map(\.isActive) == [false, false, true])
        #expect(projection.pane(for: "%9")?.columns == 60)
        #expect(projection.pane(for: "%11")?.rows == 20)
    }

    @Test func cellRoutingLeavesTmuxDividersAndOutsideCellsUnassigned() throws {
        let layout = try #require(SSHTmuxLayout(validating: Self.wire(mixedBody)))
        let projection = try #require(SSHTmuxPaneProjection(layout: layout))

        #expect(projection.pane(atColumn: 0, row: 0)?.id == "%7")
        #expect(projection.pane(atColumn: 59, row: 39)?.id == "%7")
        #expect(projection.pane(atColumn: 60, row: 0) == nil) // horizontal divider
        #expect(projection.pane(atColumn: 61, row: 0)?.id == "%9")
        #expect(projection.pane(atColumn: 61, row: 19) == nil) // vertical divider
        #expect(projection.pane(atColumn: 61, row: 20)?.id == "%11")
        #expect(projection.pane(atColumn: 121, row: 0) == nil)
        #expect(projection.pane(atColumn: 0, row: -1) == nil)
    }

    @Test func unknownActivePaneIsRefusedAndNoActiveMetadataIsSafe() throws {
        let layout = try #require(SSHTmuxLayout(validating: Self.wire("80x24,0,0,2")))
        #expect(SSHTmuxPaneProjection(layout: layout, activePaneID: "%99") == nil)

        let projection = try #require(SSHTmuxPaneProjection(layout: layout))
        #expect(projection.activePaneID == nil)
        #expect(projection.panes.allSatisfy { !$0.isActive })
        #expect(projection.pane(for: "%2")?.contains(column: 79, row: 23) == true)
        #expect(projection.pane(for: "%2")?.contains(column: 80, row: 23) == false)
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
