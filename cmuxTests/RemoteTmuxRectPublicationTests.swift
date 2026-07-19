import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct RemoteTmuxRectPublicationTests {
    /// A connection in attached control mode with a live stdin writer and the
    /// attach block drained, so the FIFO head is the initial `list-windows`.
    private func attachedConnection() -> (
        connection: RemoteTmuxControlConnection,
        writer: RemoteTmuxControlPipeWriter,
        pipe: Pipe
    ) {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-rect-publication-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        return (connection, writer, pipe)
    }

    private func reply(
        _ connection: RemoteTmuxControlConnection, lines: [String], isError: Bool = false
    ) {
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: lines, isError: isError)
        )
    }

    /// Publishes window @1 as a single 80×24 pane %0 (list-windows reply +
    /// its rects reply), leaving the FIFO empty.
    private func publishSinglePaneWindow(_ connection: RemoteTmuxControlConnection) {
        reply(connection, lines: ["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] main"])
        reply(connection, lines: ["%0 0 0 80 24 1 off :0 \"ejc3-mac\""])
    }

    private func paneRect(in node: RemoteTmuxLayoutNode, id: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        switch node.content {
        case let .pane(paneId):
            return paneId == id ? (node.x, node.y, node.width, node.height) : nil
        case let .horizontal(children), let .vertical(children):
            for child in children {
                if let hit = paneRect(in: child, id: id) { return hit }
            }
            return nil
        }
    }

    private func paneRectsFIFOCount(_ connection: RemoteTmuxControlConnection) -> Int {
        connection.pendingCommandKindsForTesting.filter {
            if case .paneRects = $0 { return true }
            return false
        }.count
    }

    @Test func layoutChangeNotifiesOnlyOnItsRectsReply() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        // The layout string is quarantined: no notify, observers still see the
        // last verified tree, and one rects fetch is on the FIFO.
        #expect(notifies == 0)
        #expect(connection.windowsByID[1]?.layout.width == 80)
        #expect(paneRectsFIFOCount(connection) == 1)

        reply(connection, lines: [
            "%0 0 0 60 40 1 off :0 \"left pane\"",
            "%2 61 0 59 40 0 off :1 \"right\"",
        ])
        #expect(notifies == 1)
        #expect(paneRect(in: connection.windowsByID[1]!.layout, id: 2)! == (61, 0, 59, 40))
        #expect(connection.paneHeaderLabels[0] == "0 \"left pane\"")
        #expect(connection.paneHeaderLabels[2] == "1 \"right\"")
        #expect(connection.windowTitleRowPlacements[1] == nil)
    }

    @Test func windowRenameWhileLayoutIsPendingPublishesTheNewName() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        connection.handleMessageForTesting(.layoutChange(
            windowId: 2,
            layout: "e5d1,90x30,0,0,5",
            visibleLayout: nil,
            zoomed: false
        ))
        connection.handleMessageForTesting(.windowRenamed(windowId: 2, name: "renamed"))
        reply(connection, lines: ["%5 0 0 90 30 1 off :zsh"])

        #expect(connection.windowsByID[2]?.name == "renamed")
    }

    @Test func windowRenameWhileInitialTopologyIsStagedPublishesTheNewName() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }

        reply(connection, lines: [
            "@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] one",
            "@2 e5d1,90x30,0,0,5 e5d1,90x30,0,0,5 [] two",
        ])
        let kinds = connection.pendingCommandKindsForTesting
        guard case let .paneRects(firstWindow, _) = kinds.first else {
            Issue.record("expected a paneRects fetch at the FIFO head, got \(kinds)")
            return
        }
        let firstPane = firstWindow == 1 ? 0 : 5
        let secondWindow = firstWindow == 1 ? 2 : 1
        let secondPane = secondWindow == 1 ? 0 : 5
        let firstSize = firstWindow == 1 ? "80 24" : "90 30"
        let secondSize = secondWindow == 1 ? "80 24" : "90 30"

        reply(connection, lines: ["%\(firstPane) 0 0 \(firstSize) 1 off :zsh"])
        connection.handleMessageForTesting(.windowRenamed(
            windowId: firstWindow,
            name: "renamed while staged"
        ))
        reply(connection, lines: ["%\(secondPane) 0 0 \(secondSize) 1 off :zsh"])

        #expect(connection.windowsByID[firstWindow]?.name == "renamed while staged")
    }

    @Test func stagedWindowRenameSurvivesAFollowUpLayoutChange() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }

        reply(connection, lines: [
            "@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] one",
            "@2 e5d1,90x30,0,0,5 e5d1,90x30,0,0,5 [] two",
        ])
        let kinds = connection.pendingCommandKindsForTesting
        guard case let .paneRects(firstWindow, _) = kinds.first else {
            Issue.record("expected a paneRects fetch at the FIFO head, got \(kinds)")
            return
        }
        let firstPane = firstWindow == 1 ? 0 : 5
        let secondWindow = firstWindow == 1 ? 2 : 1
        let secondPane = secondWindow == 1 ? 0 : 5
        let firstSize = firstWindow == 1 ? "80 24" : "90 30"
        let secondSize = secondWindow == 1 ? "80 24" : "90 30"

        reply(connection, lines: ["%\(firstPane) 0 0 \(firstSize) 1 off :zsh"])
        connection.handleMessageForTesting(.windowRenamed(
            windowId: firstWindow,
            name: "renamed before restage"
        ))
        connection.handleMessageForTesting(.layoutChange(
            windowId: firstWindow,
            layout: firstWindow == 1 ? "f92f,80x24,0,0,0" : "e5d1,90x30,0,0,5",
            visibleLayout: nil,
            zoomed: false
        ))

        reply(connection, lines: ["%\(secondPane) 0 0 \(secondSize) 1 off :zsh"])
        reply(connection, lines: ["%\(firstPane) 0 0 \(firstSize) 1 off :zsh"])

        #expect(connection.windowsByID[firstWindow]?.name == "renamed before restage")
    }

    @Test func rectsErrorRetriesOnceThenKeepsLastVerifiedTree() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        reply(connection, lines: ["can't find window: @1"], isError: true)
        // One retry lands on the FIFO…
        #expect(paneRectsFIFOCount(connection) == 1)
        reply(connection, lines: ["can't find window: @1"], isError: true)
        // …then the pending layout is dropped: observers keep the verified
        // 80×24 tree, never the raw 120×40 string geometry, and no fetch loops.
        #expect(paneRectsFIFOCount(connection) == 0)
        #expect(notifies == 0)
        #expect(connection.windowsByID[1]?.layout.width == 80)
    }

    @Test func initialTopologyPublishesAtomicallyWhenTheLastWindowVerifies() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        reply(connection, lines: [
            "@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] one",
            "@2 e5d1,90x30,0,0,5 e5d1,90x30,0,0,5 [] two",
        ])
        notifies = 0 // the list-windows order/name notify is not under test
        let kinds = connection.pendingCommandKindsForTesting
        #expect(kinds.count == 2)
        guard case let .paneRects(firstWindow, _) = kinds[0] else {
            Issue.record("expected a paneRects fetch at the FIFO head, got \(kinds)")
            return
        }
        let firstPane = firstWindow == 1 ? 0 : 5
        let secondPane = firstWindow == 1 ? 5 : 0

        reply(connection, lines: ["%\(firstPane) 0 0 80 24 1 off :zsh"])
        // The FIRST reply publishes nothing: the initial topology flushes
        // atomically, so tab creation order can never follow reply arrival
        // order (which window answers first is a race between round trips).
        #expect(connection.windowsByID.isEmpty)
        #expect(notifies == 0)

        reply(connection, lines: ["%\(secondPane) 0 0 90 30 1 off :vim"])
        // The LAST reply flushes both windows in one publish + one notify.
        #expect(connection.windowsByID[1] != nil)
        #expect(connection.windowsByID[2] != nil)
        #expect(notifies == 1)
    }

    @Test func staleGenerationReplyIsDiscardedAndRefetched() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        // A newer layout supersedes the in-flight fetch: coalesced (no second
        // send), generation bumped.
        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{80x40,0,0,0,39x40,81,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        #expect(paneRectsFIFOCount(connection) == 1)

        // The reply for the SUPERSEDED fetch is stale: discarded (no publish,
        // no notify) and the owed fetch for the newer generation goes out.
        reply(connection, lines: ["%0 0 0 60 40 1 off :stale", "%2 61 0 59 40 0 off :stale"])
        #expect(notifies == 0)
        #expect(connection.windowsByID[1]?.layout.width == 80)
        #expect(paneRectsFIFOCount(connection) == 1)

        reply(connection, lines: ["%0 0 0 80 40 1 off :wide", "%2 81 0 39 40 0 off :narrow"])
        #expect(notifies == 1)
        #expect(paneRect(in: connection.windowsByID[1]!.layout, id: 2)! == (81, 0, 39, 40))
    }

    @Test func layoutWhileDisconnectedStaysQuarantinedWithoutSending() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        // No writer, not connected: the fetch send fails. The raw tree must
        // stay quarantined (the reconnect's list-windows reseed re-stages it).
        connection.handleMessageForTesting(.layoutChange(
            windowId: 1, layout: "f92f,80x24,0,0,0", visibleLayout: nil, zoomed: false
        ))
        #expect(connection.windowsByID.isEmpty)
        #expect(connection.pendingCommandKindsForTesting.isEmpty)
    }

    @Test func rectsReplySeedsActivePaneAndWindowPaneChangedOverridesIt() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }

        var observed: (windowId: Int, paneId: Int)?
        let token = connection.addObserver(onActivePaneChanged: { observed = ($0, $1) })
        defer { connection.removeObserver(token) }

        reply(connection, lines: ["@1 abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} [] main"])
        reply(connection, lines: ["%0 0 0 60 40 0 off :left", "%2 61 0 59 40 1 off :right"])
        // The fetch's #{pane_active} seeds the initial active pane…
        #expect(connection.activePaneByWindow[1] == 2)
        #expect(observed! == (1, 2))

        // …and live %window-pane-changed remains the authority afterwards.
        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 0))
        #expect(connection.activePaneByWindow[1] == 0)
        #expect(observed! == (1, 0))
    }

    @Test func mirrorAdoptsRemoteActivePaneAndCopiesLabelsOnReconcile() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        reply(connection, lines: ["@1 abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} [] main"])
        reply(connection, lines: ["%0 0 1 60 39 1 top :0 \"left\"", "%2 61 1 59 39 0 top :1 \"right\""])

        let published = connection.windowsByID[1]!.layout
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: published,
            geometrySource: nil,
            makePanel: { _ in nil }
        )
        mirror.reconcile(layout: published)
        // The strip labels ride reconcile from the connection's fetch results,
        // as does whether tmux is drawing header rows (labels render only then).
        #expect(mirror.paneHeaderLabels == [0: "0 \"left\"", 2: "1 \"right\""])
        #expect(mirror.tmuxTitleRowPlacement == .top)
        // On first attach the active-pane event fires BEFORE this mirror
        // exists, so reconcile must adopt the connection's known active pane
        // — otherwise the dot is missing until the next pane switch.
        #expect(mirror.activePaneId == 0)

        // tmux's %window-pane-changed moves the dot (via the session mirror's
        // noteRemoteActivePane call), including before any local focus.
        mirror.noteRemoteActivePane(2)
        #expect(mirror.activePaneId == 2)
    }

    @Test func partialRectsReplyRetriesThenKeepsLastVerifiedTree() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        // The reply covers only ONE of the tree's two panes: publishing it
        // would smuggle pane %2's raw layout-string geometry into the
        // verified tree (patchingLeafRects leaves unknown leaves untouched).
        reply(connection, lines: ["%0 0 0 60 40 1 off :left"])
        #expect(connection.windowsByID[1]?.layout.width == 80)
        #expect(paneRectsFIFOCount(connection) == 1)
        // A zero-sized rect is a mid-resize artifact, equally unverified.
        reply(connection, lines: ["%0 0 0 60 40 1 off :left", "%2 61 0 0 40 0 off :right"])
        #expect(notifies == 0)
        #expect(connection.windowsByID[1]?.layout.width == 80)
        #expect(paneRectsFIFOCount(connection) == 0)
    }

    @Test func initialBatchDrainsWhenOneWindowErrorsOut() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        reply(connection, lines: [
            "@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] one",
            "@2 e5d1,90x30,0,0,5 e5d1,90x30,0,0,5 [] two",
        ])
        notifies = 0
        let kinds = connection.pendingCommandKindsForTesting
        guard case let .paneRects(erroringWindow, _) = kinds.first else {
            Issue.record("expected a paneRects fetch at the FIFO head, got \(kinds)")
            return
        }
        let healthyWindow = erroringWindow == 1 ? 2 : 1
        let healthyPane = healthyWindow == 1 ? 0 : 5
        let healthySize = healthyWindow == 1 ? "80 24" : "90 30"

        // FIFO: [errorer, healthy] -> error consumes head and retries
        // (appends), healthy publishes into staging, the retry errors out and
        // resolves the batch — which must flush the healthy window rather
        // than wait forever on the dead one.
        reply(connection, lines: ["can't find window"], isError: true)
        reply(connection, lines: ["%\(healthyPane) 0 0 \(healthySize) 1 off :sh"])
        #expect(connection.windowsByID.isEmpty)
        reply(connection, lines: ["can't find window"], isError: true)
        #expect(connection.windowsByID[healthyWindow] != nil)
        #expect(connection.windowsByID[erroringWindow] == nil)
        #expect(notifies == 1)
    }

    @Test func styleTokensAreStrippedFromExpandedHeaderFormats() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        // tmux's default pane-border-format marks the active pane with
        // #[reverse]; the dot carries that signal here, so style tokens are
        // dropped and only the text is faithful.
        reply(connection, lines: ["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] one"])
        reply(connection, lines: ["%0 0 1 80 23 1 top :#[reverse]0#[default] \"ejc3-mac\""])
        #expect(connection.paneHeaderLabels[0] == "0 \"ejc3-mac\"")
        #expect(connection.windowTitleRowPlacements[1] == .top)
    }

    @Test func headerSubscriptionKeepsLabelsLiveBetweenLayoutEvents() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        // A program retitles its pane with NO layout change: the per-pane
        // subscription pushes the re-expanded format the moment tmux would
        // redraw its own header row.
        connection.handleMessageForTesting(.subscriptionChanged(
            name: "cmux_hdr_0", value: "#[reverse]0#[default] \"vim main.swift\""
        ))
        #expect(connection.paneHeaderLabels[0] == "0 \"vim main.swift\"")
        #expect(notifies == 1)

        // Same value again: no re-notify (equality-guarded).
        connection.handleMessageForTesting(.subscriptionChanged(
            name: "cmux_hdr_0", value: "#[reverse]0#[default] \"vim main.swift\""
        ))
        #expect(notifies == 1)
    }

    @Test func rectsReplyRepairsAStaleActivePane() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        reply(connection, lines: ["@1 abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} [] main"])
        reply(connection, lines: ["%0 0 0 60 40 1 0 left", "%2 61 0 59 40 0 1 right"])
        #expect(connection.activePaneByWindow[1] == 0)

        var observed: (windowId: Int, paneId: Int)?
        let token = connection.addObserver(onActivePaneChanged: { observed = ($0, $1) })
        defer { connection.removeObserver(token) }

        // An active-pane change with no %window-pane-changed to replay (it
        // happened during an outage): the next fetch's #{pane_active}
        // snapshot must repair the tracked pane, not defer to the stale one.
        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        reply(connection, lines: ["%0 0 0 60 40 0 off :left", "%2 61 0 59 40 1 off :right"])
        #expect(connection.activePaneByWindow[1] == 2)
        #expect(observed! == (1, 2))
    }

    @Test func rectsVerifiedPublishPrunesRemovedPaneDiagnosticState() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        // Publish the two-pane window through the verified path: list-windows
        // reply, then its rects reply.
        reply(connection, lines: [
            "@1 abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} [] main"
        ])
        reply(connection, lines: ["%4 0 0 60 40 1 off :4 \"left\"", "%5 61 0 59 40 0 off :5 \"right\""])

        connection.handleMessageForTesting(.output(paneId: 4, data: Data("left".utf8)))
        connection.handleMessageForTesting(.output(paneId: 5, data: Data("right".utf8)))
        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_reflow_4", value: "0|zsh"))
        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_reflow_5", value: "1|vim"))

        // Removing pane 5 publishes through the layout's verified rects reply,
        // which prunes the dead pane's diagnostic state.
        connection.handleMessageForTesting(.layoutChange(
            windowId: 1, layout: "f92f,80x24,0,0,4", visibleLayout: nil, zoomed: false
        ))
        reply(connection, lines: ["%4 0 0 80 24 1 off :4 \"left\""])

        #expect(connection.snapshot().paneOutputByteCounts[4] == 4)
        #expect(connection.snapshot().paneOutputByteCounts[5] == nil)
        #expect(connection.paneForegroundStates[4] != nil)
        #expect(connection.paneForegroundStates[5] == nil)
    }

}
