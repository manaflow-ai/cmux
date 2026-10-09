import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import Foundation
import Testing

@Suite struct SSHTmuxPendingInputTests {
    private let metadata = [Data("%2 80 24 3 2 0 0 23 1 0 0 0 1 0 1 0 0 0 0 0".utf8)]

    @Test func pendingControlStringsFollowEverySnapshotRestorationEscape() throws {
        let prefix = Data("\u{1b}]0;title\\part\n".utf8)
        let replay = try SSHTmuxSnapshot.replay(lines: [], metadata: metadata, pane: "%2", cols: 80, rows: 24,
                                              pendingInput: [Data("\\033]0;title\\134part\\012".utf8)])
        let expectedSuffix = Data("\u{1b}[3;4H".utf8) + prefix
        #expect(replay.suffix(expectedSuffix.count) == expectedSuffix)
    }

    @Test func pendingControlStringUTF8BytesArePreservedUntilLiveOutputCompletesThem() throws {
        let replay = try SSHTmuxSnapshot.replay(lines: [], metadata: metadata, pane: "%2", cols: 80, rows: 24,
                                              pendingInput: [Data("\\033]0;\\342\\202".utf8)])
        #expect(replay.suffix(2) == Data([0xe2, 0x82]))
        #expect(String(data: Data(replay.suffix(2)) + Data([0xac]), encoding: .utf8) == "€")
    }

    @Test func pendingStateRejectsMalformedEscapesMultipleLinesAndBothSizeBounds() {
        let invalid = [
            [Data("\\12".utf8)],
            [Data(), Data()],
            [Data(repeating: 65, count: SSHTmuxSnapshot.maximumPendingBytes + 1)],
            [Data(repeating: 65, count: SSHTmuxSnapshot.maximumPendingBytes * 4 + 1)],
        ]
        for pending in invalid {
            #expect(throws: SSHSessionFailure.shellRejected) {
                try SSHTmuxSnapshot.replay(lines: [], metadata: metadata, pane: "%2", cols: 80, rows: 24,
                                          pendingInput: pending)
            }
        }
    }

    @Test func emptyPendingStateDoesNotChangeTheVisibleSnapshot() throws {
        let normal = try SSHTmuxSnapshot.replay(lines: [], metadata: metadata, pane: "%2", cols: 80, rows: 24)
        let empty = try SSHTmuxSnapshot.replay(lines: [], metadata: metadata, pane: "%2", cols: 80, rows: 24,
                                             pendingInput: [Data()])
        #expect(normal == empty)
    }
}
