import AppKit
import CmuxRemoteSession
import CmuxTerminal
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

    /// A single-pane display's size claim must be bounded by the window
    /// hosting its surface. The claim hooks read the surface's RENDERED grid,
    /// and rendered content is downstream of SwiftUI layout: when a hosting
    /// ancestor adopts the content's ideal size, the surface renders at the
    /// inflated size, the wider grid claims a wider tmux window, tmux's
    /// reflow grows the content ideal again, and the loop amplifies without
    /// bound (captured live: claims growing ~1.5 columns per 100ms to 781
    /// columns, a hosting view at 6373pt inside a 1728pt window). The
    /// hosting window is the one measurement in that chain content cannot
    /// inflate, so no claim may exceed what its content area divides to at
    /// the sample's cell size.
    @Test func singlePaneDisplayClaimIsBoundedByTheHostingWindow() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        let sessionName = "claim-bound"
        let connection = RemoteTmuxControlConnection(host: host, sessionName: sessionName)
        // One single-pane window, published before the mirror attaches so the
        // rebuild creates its display tab (and wires the claim hooks).
        let paneLayout = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0, content: .pane(7)
        )
        connection.windowsByID = [
            3: RemoteTmuxWindow(id: 3, width: 80, height: 24, layout: paneLayout)
        ]
        connection.windowOrder = [3]
        connection.publishedWindowIdByPane = [7: 3]
        controller.cacheConnection(connection)
        #expect(try controller.mirrorSession(host: host, sessionName: sessionName, into: manager))
        defer { controller.detach(host: host, sessionName: sessionName) }

        let workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        let mirror = try #require(workspace.remoteTmuxSessionMirror)
        let panelId = try #require(mirror.panelIdByWindow[3])
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let surface = panel.surface

        // Host the display surface in a real, visible window of known size.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 504, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)
        surface.hostedView.frame = contentView.bounds
        contentView.addSubview(surface.hostedView)
        window.makeKeyAndOrderFront(nil)

        // The amplified feedback: a rendered grid far beyond anything the
        // 504pt window can hold, at 7x14pt cells (14x28px at 2x).
        let report = try #require(surface.onManualSizeApplied)
        report(TerminalSurfaceRawSizingSample(
            columns: 781, rows: 200,
            cellWidthPx: 14, cellHeightPx: 28,
            surfaceWidthPx: 781 * 14 + 8, surfaceHeightPx: 200 * 28,
            viewBoundsPt: CGSize(width: 5_471, height: 2_800),
            backingScale: 2
        ))

        let claim = try #require(connection.lastWindowSizes[3])
        let bound = window.contentLayoutRect.size
        let ceilingColumns = Int(bound.width / 7)
        let ceilingRows = Int(bound.height / 14)
        #expect(
            claim.0 <= ceilingColumns,
            "claimed \(claim.0) columns from rendered-content feedback — the \(Int(bound.width))pt window holds at most \(ceilingColumns)"
        )
        #expect(
            claim.1 <= ceilingRows,
            "claimed \(claim.1) rows from rendered-content feedback — the \(Int(bound.height))pt window holds at most \(ceilingRows)"
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

    /// tmux is the only authority on whether a size claim actually landed.
    /// The sent-pins ledger dedups resends, so a pin the server never
    /// honored wedges silently. The reply was lost across a transport gap,
    /// or a co-client raced it, or the window-size mode changed — either
    /// way the ledger says delivered and dedup suppresses every retry. The
    /// window then sits columns wide of the claim and mirrors render short
    /// of the assignment; the live fuzz caught panes rendering 83 columns
    /// against an assignment of 86, persisting through settle. Every
    /// %layout-change names the window's actual size. A layout that
    /// disagrees with a delivered claim re-arms the claim.
    @Test func layoutDisagreeingWithDeliveredClaimRearmsThePin() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 3, columns: 83, rows: 40)
        connection.sentWindowSizes[3] = (83, 40)
        connection.applyLayout(windowId: 3, layout: "f92f,86x40,0,0,7")
        #expect(
            connection.sentWindowSizes[3] == nil,
            "a delivered claim tmux disagrees with must clear the ledger so the next send is not deduped away"
        )
        #expect(connection.lastWindowSizes[3]?.0 == 83, "the desired claim itself must not change")
    }

    /// The re-arm is budgeted per disagreement episode: an infeasible claim
    /// (tmux clamps a window up to its tree minimum) disagrees forever, and
    /// an unbounded re-arm would ping the server once per layout event for
    /// the rest of the session. Agreement or a new claim value opens the
    /// next episode.
    @Test func claimParityRearmIsBudgetedPerEpisode() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 3, columns: 83, rows: 40)
        for round in 1...5 {
            connection.sentWindowSizes[3] = (83, 40)
            connection.applyLayout(windowId: 3, layout: "f92f,86x40,0,0,7")
            if round <= 3 {
                #expect(
                    connection.sentWindowSizes[3] == nil,
                    "round \(round) is within the episode budget and must re-arm"
                )
            } else {
                #expect(
                    connection.sentWindowSizes[3] != nil,
                    "round \(round) must not re-arm — the episode budget is spent"
                )
            }
        }

        // Agreement closes the episode and restores the budget.
        connection.applyLayout(windowId: 3, layout: "f92f,83x40,0,0,7")
        connection.sentWindowSizes[3] = (83, 40)
        connection.applyLayout(windowId: 3, layout: "f92f,86x40,0,0,7")
        #expect(
            connection.sentWindowSizes[3] == nil,
            "agreement resets the budget for the next episode"
        )

        // A new claim value opens a fresh episode too.
        connection.sentWindowSizes[3] = (83, 40)
        connection.applyLayout(windowId: 3, layout: "f92f,86x40,0,0,7")
        connection.sentWindowSizes[3] = (83, 40)
        connection.applyLayout(windowId: 3, layout: "f92f,86x40,0,0,7")
        connection.setWindowSize(windowId: 3, columns: 90, rows: 40)
        connection.sentWindowSizes[3] = (90, 40)
        connection.applyLayout(windowId: 3, layout: "f92f,86x40,0,0,7")
        #expect(
            connection.sentWindowSizes[3] == nil,
            "a changed claim value must open a fresh episode with a fresh budget"
        )
    }

    /// Attach floods deliver layouts before any claim is sent. Those
    /// disagreements have no delivered claim to re-arm and must not spend
    /// the episode budget, or the budget would be gone before the first
    /// real wedge.
    @Test func layoutDisagreementWithoutDeliveredClaimSpendsNoBudget() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 3, columns: 83, rows: 40)
        for _ in 0..<5 {
            connection.applyLayout(windowId: 3, layout: "f92f,86x40,0,0,7")
        }
        connection.sentWindowSizes[3] = (83, 40)
        connection.applyLayout(windowId: 3, layout: "f92f,86x40,0,0,7")
        #expect(
            connection.sentWindowSizes[3] == nil,
            "no budget may be spent while no delivered claim existed"
        )
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
