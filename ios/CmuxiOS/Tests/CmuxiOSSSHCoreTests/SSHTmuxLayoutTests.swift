@testable import CmuxiOSSSHCore
import Foundation
import Testing

@Suite struct SSHTmuxLayoutTests {
    // A checksum-bearing single pane from tmux 3.3a's CONTROL MODE manual.
    private let single = "b25f,80x24,0,0,2"
    private let mixedBody = "121x40,0,0{60x40,0,0,7,60x40,61,0[60x19,61,0,9,60x20,61,20,11]}"

    @Test func publishedTmuxFixtureKeepsTheHostPaneIdentity() throws {
        let layout = try #require(SSHTmuxLayout(validating: single))
        guard case .pane(let pane) = layout.root else { Issue.record("expected one pane"); return }
        #expect(pane.id == "%2")
        #expect(pane.frame.columns == 80)
        #expect(pane.frame.rows == 24)
        #expect(layout.panes == [pane])
        // Older select-layout strings can omit ids. They cannot identify
        // panes for a renderer, even though tmux can apply such a layout.
        #expect(SSHTmuxLayout(validating: "bb62,159x48,0,0{79x48,0,0,79x48,80,0}") == nil)
    }

    @Test func nestedSplitsPreserveAxisCellGeometryAndStableOrdering() throws {
        let layout = try #require(SSHTmuxLayout(validating: Self.wire(mixedBody)))
        #expect(layout.panes.map(\.id) == ["%7", "%9", "%11"])
        guard case .split(let frame, .leftRight, let children) = layout.root,
              case .split(_, .topBottom, let right) = children[1] else {
            Issue.record("expected nested horizontal and vertical splits")
            return
        }
        #expect(frame.columns == 121)
        #expect(frame.rows == 40)
        #expect(right.count == 2)
        #expect(layout.panes[2].frame.column == 61)
        #expect(layout.panes[2].frame.row == 20)
        #expect(layout.panes[2].frame.rows == 20)
    }

    @Test func checksumTruncationAndTrailingBytesAreRejected() {
        #expect(SSHTmuxLayout(validating: single.replacingOccurrences(of: "80x", with: "81x")) == nil)
        #expect(SSHTmuxLayout(validating: String(single.dropLast())) == nil)
        #expect(SSHTmuxLayout(validating: Self.wire("80x24,0,0,2 trailing")) == nil)
        #expect(SSHTmuxLayout(validating: Self.wire(String(mixedBody.dropLast()))) == nil)
    }

    @Test func gapsOverlapsForeignOriginsAndDuplicatePanesAreRejected() {
        let invalid = [
            "3x1,0,0{1x1,0,0,0,1x1,1,0,1}", // Overlap at the border.
            "4x1,0,0{1x1,0,0,0,1x1,3,0,1}", // Extra gap.
            "3x2,0,0{1x2,0,0,0,1x1,2,1,1}", // Cross-axis mismatch.
            "3x1,0,0{1x1,0,0,0,1x1,2,0,00}", // Same numeric pane id.
            "1x1,0,0{1x1,0,0,0}", // Not a split.
            "1x1,1,0,0", // Root is not the host's origin.
        ]
        for body in invalid { #expect(SSHTmuxLayout(validating: Self.wire(body)) == nil) }
    }

    @Test func malformedAndOverflowingNumbersAreRejected() {
        let invalid = ["0x1,0,0,0", "1x0,0,0,0", "65536x1,0,0,0", "1x1,65535,0,0",
                       "1x1,0,0,4294967296", "1x1,0,0,-1", "1x1,0,0,9999999999999999999999",
                       "1x1,0,0,٢", "1x1,0,0,2;kill-server", "1x1,0,0,2\n"]
        for body in invalid { #expect(SSHTmuxLayout(validating: Self.wire(body)) == nil) }
        #expect(SSHTmuxLayout(validating: Self.wire("65535x1,0,0,4294967295")) != nil)
    }

    @Test func bytePaneAndDepthBudgetsAreEnforcedAtTheirBoundaries() {
        #expect(SSHTmuxLayout(validating: String(repeating: "0", count: SSHTmuxLayout.maximumBytes + 1)) == nil)
        #expect(SSHTmuxLayout(validating: Self.wire(Self.flat(panes: 256)))?.panes.count == 256)
        #expect(SSHTmuxLayout(validating: Self.wire(Self.flat(panes: 257))) == nil)
        #expect(SSHTmuxLayout(validating: Self.wire(Self.nested(depth: 32)))?.panes.count == 32)
        #expect(SSHTmuxLayout(validating: Self.wire(Self.nested(depth: 33))) == nil)
    }

    @Test func discoveryCarriesOnlyLayoutWhosePanesMatchTheSameListing() throws {
        let discovery = SSHSessionDiscovery()
        let listing = Self.listing + "L2\t@9\t" + Self.wire(mixedBody) + "\n"
        let window = try #require(discovery.parse(listing).first?.windows.first)
        #expect(window.layout?.panes.map(\.id) == ["%7", "%9", "%11"])
        #expect(window.target.surfaceID == discovery.parse(Self.listing).first?.windows.first?.target.surfaceID)
        let missingPane = listing.replacingOccurrences(of: "P2\t@9\t%11\t0\n", with: "")
        let mismatched = try #require(discovery.parse(missingPane).first?.windows.first)
        #expect(mismatched.layout == nil)
        #expect(mismatched.target == window.target)
    }

    @Test func conflictingOrMalformedLayoutRowsCannotOverrideAnEarlierSnapshot() throws {
        let discovery = SSHSessionDiscovery()
        let row = "L2\t@9\t" + Self.wire(mixedBody) + "\n"
        #expect(discovery.parse(Self.listing + row + row).first?.windows.first?.layout != nil)
        let conflict = "L2\t@9\t" + Self.wire("1x1,0,0,9") + "\n"
        #expect(discovery.parse(Self.listing + row + conflict + row).first?.windows.first?.layout == nil)
        #expect(discovery.parse(Self.listing + row + "L2\t@9\tbroken\n" + row).first?.windows.first?.layout == nil)
    }

    private static let listing = """
    @tmux2\t/usr/bin/tmux
    S\twork\t1\t0\t1
    W2\twork\t0\t1\t$1\t@9\t42\t100\tshell
    P2\t@9\t%7\t0
    P2\t@9\t%9\t1
    P2\t@9\t%11\t0

    """

    /// Makes malformed geometry carry a valid checksum so each rejection
    /// above exercises the structural validator rather than the checksum.
    private static func wire(_ body: String) -> String {
        var checksum: UInt16 = 0
        for byte in body.utf8 {
            checksum = (checksum >> 1) | ((checksum & 1) << 15)
            checksum &+= UInt16(byte)
        }
        return String(format: "%04x,", checksum) + body
    }

    private static func flat(panes: Int) -> String {
        let children = (0..<panes).map { "1x1,\($0 * 2),0,\($0)" }.joined(separator: ",")
        return "\(panes * 2 - 1)x1,0,0{\(children)}"
    }

    private static func nested(depth: Int, column: Int = 0) -> String {
        guard depth > 1 else { return "1x1,\(column),0,\(column)" }
        return "\(depth * 2 - 1)x1,\(column),0{1x1,\(column),0,\(column),\(nested(depth: depth - 1, column: column + 2))}"
    }
}
