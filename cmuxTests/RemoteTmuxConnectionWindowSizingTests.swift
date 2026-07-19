import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct RemoteTmuxConnectionWindowSizingTests {
    private func makeConnection() -> RemoteTmuxControlConnection {
        RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
    }

    @Test func windowSizesAreTrackedPerWindow() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 0, columns: 98, rows: 35)
        connection.setWindowSize(windowId: 7, columns: 60, rows: 20)
        #expect(connection.lastWindowSizes[0]?.0 == 98)
        #expect(connection.lastWindowSizes[7]?.0 == 60)
        connection.setWindowSize(windowId: 0, columns: 98, rows: 35) // dedup no-op
        #expect(connection.lastWindowSizes[0]?.0 == 98)
    }

    @Test func perWindowRejectionFallsBackToSessionWide() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 0, columns: 98, rows: 35)
        connection.notePerWindowSizeRejected()
        #expect(connection.supportsPerWindowSize == false)
        // Requests keep flowing through the session-wide path (recorded for
        // the reconnect reseed even while not connected).
        connection.setWindowSize(windowId: 3, columns: 80, rows: 24)
        #expect(connection.lastRequestedClientSize?.columns == 80)
    }

    @Test func degenerateSizesAreIgnored() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 0, columns: 0, rows: 35)
        connection.setWindowSize(windowId: 0, columns: 98, rows: -1)
        #expect(connection.lastWindowSizes[0] == nil)
    }

    @Test func claimMaximaTrackReplacementRemovalAndRetention() {
        let connection = makeConnection()
        connection.recordWindowSizeClaim(windowId: 1, columns: 120, rows: 30)
        connection.recordWindowSizeClaim(windowId: 2, columns: 90, rows: 44)
        #expect(connection.maximumWindowClaimColumns == 120)
        #expect(connection.maximumWindowClaimRows == 44)

        connection.recordWindowSizeClaim(windowId: 1, columns: 80, rows: 20)
        #expect(connection.maximumWindowClaimColumns == 90)
        #expect(connection.maximumWindowClaimRows == 44)

        connection.removeWindowSizeClaim(windowId: 2)
        #expect(connection.maximumWindowClaimColumns == 80)
        #expect(connection.maximumWindowClaimRows == 20)

        connection.recordWindowSizeClaim(windowId: 3, columns: 140, rows: 50)
        connection.retainWindowSizeClaims(for: [1])
        #expect(Set(connection.lastWindowSizes.keys) == [1])
        #expect(connection.maximumWindowClaimColumns == 80)
        #expect(connection.maximumWindowClaimRows == 20)
    }

    @Test func clientEnvelopeTracksLiveClaimMaximaDownward() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 1, columns: 120, rows: 30)
        connection.setWindowSize(windowId: 2, columns: 90, rows: 44)
        #expect(connection.lastRequestedClientSize?.columns == 120)
        #expect(connection.lastRequestedClientSize?.rows == 44)

        connection.setWindowSize(windowId: 1, columns: 80, rows: 20)
        #expect(connection.lastRequestedClientSize?.columns == 90)
        #expect(connection.lastRequestedClientSize?.rows == 44)

        connection.removeWindowSizeClaim(windowId: 2)
        #expect(connection.lastRequestedClientSize?.columns == 80)
        #expect(connection.lastRequestedClientSize?.rows == 20)

        connection.setWindowSize(windowId: 3, columns: 140, rows: 50)
        connection.retainWindowSizeClaims(for: [1])
        #expect(connection.lastRequestedClientSize?.columns == 80)
        #expect(connection.lastRequestedClientSize?.rows == 20)
    }

    @Test func returningToSentSizeCancelsDifferentPendingClaim() {
        let connection = makeConnection()
        connection.handleMessageForTesting(.enter)
        connection.sentWindowSizes[4] = (100, 30)
        connection.recordWindowSizeClaim(windowId: 4, columns: 120, rows: 30)
        connection.windowSizeDebounceTasks[4] = Task {}

        connection.setWindowSize(windowId: 4, columns: 100, rows: 30)

        #expect(connection.lastWindowSizes[4]?.0 == 100)
        #expect(connection.windowSizeDebounceTasks[4] == nil)
    }

    @Test func pendingPaneRectPublicationIsSizingSettlementWork() {
        let connection = makeConnection()
        connection.pendingLayouts[4] = RemoteTmuxPendingLayout(
            node: RemoteTmuxLayoutNode(
                width: 80, height: 24, x: 0, y: 0, content: .pane(7)
            ),
            visibleNode: nil,
            zoomed: false,
            name: "main",
            generation: 2,
            inFlight: true
        )

        #expect(connection.hasPendingSizingSettlementWork(windowId: 4))
        #expect(!connection.hasPendingSizingSettlementWork(windowId: 5))
    }

    @Test(arguments: [
        ["kill-server"],
        ["new-session", "-d", "-s", "sizing", "-x", "180", "-y", "45"],
        ["split-window", "-h", "-t", "sizing:0"],
        ["select-layout", "-t", "sizing:0", "even-horizontal"],
        ["new-window", "-t", "sizing", "-n", "nested"],
        ["set", "-w", "-t", "sizing:0", "pane-border-status", "top"],
        ["resize-pane", "-t", "sizing:@0.%1", "-x", "13"],
        ["list-panes", "-t", "sizing:@0", "-F", "#{pane_width} #{pane_top}"],
        ["list-windows", "-t", "sizing", "-F", "#{window_id} #{window_name}"],
        ["display-message", "-p", "-t", "sizing:@0", "#{window_width}x#{window_height}"],
    ])
    func uiTestTmuxPolicyAllowsOnlyHarnessCommands(_ arguments: [String]) {
        #expect(TerminalController.isAllowedRemoteTmuxTestCommand(arguments))
    }

    @Test(arguments: [
        ["run-shell", "touch /tmp/owned"],
        ["new-session", "-d", "-s", "sizing", "-x", "180", "-y", "45", "sh -c id"],
        ["send-keys", "-t", "%1", "sh -c id", "Enter"],
        ["list-panes", "-t", "sizing", "-F", "#(id)"],
        ["split-window", "-h", "-t", "sizing", "sh -c id"],
    ])
    func uiTestTmuxPolicyRejectsExecutableArguments(_ arguments: [String]) {
        #expect(!TerminalController.isAllowedRemoteTmuxTestCommand(arguments))
    }
}
