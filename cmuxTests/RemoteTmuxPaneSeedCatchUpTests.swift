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

/// A catch-up after the control stream falls a read bound behind drops the backlog instead of
/// drawing it.
extension RemoteTmuxPaneSeedTransportTests {
    /// A catch-up drops each pane's output up to its capture instead of retaining it, so a
    /// backlog larger than the live-byte budget neither reaches the terminal nor restarts the
    /// seed. A pane already being repainted joins the catch-up, and because that repaint only
    /// captures the screen, it also gets a full-history seed behind it.
    @Test func catchUpDropsBacklogUpToTheCaptureWithoutSpendingTheSeedBudget() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        for (windowId, paneId) in [(1, 7), (2, 8)] {
            fixture.connection.windowsByID[windowId] = RemoteTmuxWindow(
                id: windowId,
                width: 80,
                height: 24,
                layout: RemoteTmuxLayoutNode(
                    width: 80, height: 24, x: 0, y: 0, content: .pane(paneId)
                )
            )
        }
        var rendered: [Int: Int] = [:]
        var seeds: [Int: RemoteTmuxPaneSeed] = [:]
        let token = fixture.connection.addObserver(
            onPaneOutput: { paneId, data in rendered[paneId, default: 0] += data.count },
            onPaneSeed: { paneId, seed in seeds[paneId] = seed }
        )
        defer { fixture.connection.removeObserver(token) }

        // Pane 8 is already being repainted and has retained output for its live filters.
        _ = try #require(fixture.connection.repaintPaneVisibleScreen(paneId: 8))
        fixture.connection.handleMessageForTesting(.output(paneId: 8, data: Data("retained".utf8)))
        #expect(fixture.connection.pendingPaneSeeds[8]?.first?.discardedOutput.isEmpty == false)

        fixture.connection.catchUpAfterFallingBehind()
        #expect(fixture.connection.pendingPaneSeeds[7]?.first?.kind == .fullHistory)
        #expect(fixture.connection.pendingPaneSeeds[8]?.map(\.kind) == [.visibleRepaint, .fullHistory])
        #expect(fixture.connection.pendingPaneSeeds[8]?.first?.discardedOutput.isEmpty == true)
        #expect(fixture.connection.pendingPaneSeedByteCount < 1_024)
        let queuedCommands = fixture.connection.pendingCommandKindsForTesting.count
        fixture.connection.catchUpAfterFallingBehind()
        #expect(
            fixture.connection.pendingCommandKindsForTesting.count == queuedCommands,
            "a second catch-up started while the first was waiting on tmux"
        )

        let backlog = Data(
            repeating: UInt8(ascii: "y"),
            count: RemoteTmuxControlConnection.maximumPendingPaneSeedLiveBytes + 1
        )
        fixture.connection.handleMessageForTesting(.output(paneId: 7, data: backlog))
        fixture.connection.handleMessageForTesting(.output(paneId: 8, data: backlog))
        #expect(rendered.isEmpty)
        #expect(fixture.connection.pendingPaneSeedByteCount < 1_024)
        #expect(!fixture.connection.snapshot().recentEvents.contains {
            $0.contains("backpressure")
        })

        finishPendingCommands(
            on: fixture.connection,
            captureRows: ["current screen"],
            paneHeight: 24,
            startingAt: 400
        )
        for paneId in [7, 8] {
            let seed = try #require(seeds[paneId])
            #expect(seed.restartsLiveStream)
            #expect(seed.discardedOutput.isEmpty)
            #expect(Self.occurrences(of: "current screen", in: seed.snapshot) == 1)
        }
        #expect(seeds[7]?.kind == .fullHistory)
        #expect(seeds[8]?.kind == .fullHistory)
        #expect(!fixture.connection.catchUp.isRunning)

        // Falling behind again later starts a new catch-up.
        fixture.connection.catchUpAfterFallingBehind()
        #expect(fixture.connection.pendingPaneSeeds[7]?.first?.dropsPreCaptureOutput == true)
    }

    /// The live output before a catch-up's capture was dropped, so the live escape filters must
    /// not resume from where that output left them: a filter left inside a title would swallow
    /// the pane's next output as title text.
    @Test func catchUpSeedRestartsTheLiveEscapeFilters() {
        let fixture = attachedConnection()
        defer { fixture.close() }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = manager.selectedWorkspace!
        workspace.isRemoteTmuxMirror = true
        let sessionMirror = RemoteTmuxSessionMirror(
            host: fixture.connection.host,
            sessionName: "work",
            connection: fixture.connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }

        // The last output before the backlog was dropped opened a screen title.
        sessionMirror.routeOutput(paneId: 7, data: Data("\u{1b}kvim".utf8))
        sessionMirror.routeSeed(
            paneId: 7,
            seed: RemoteTmuxPaneSeed(
                kind: .fullHistory,
                discardedOutput: [],
                snapshot: Data("screen".utf8),
                catchUpOutput: [],
                state: Data(),
                restartsLiveStream: true
            )
        )

        var filter = sessionMirror.titleFilters[7] ?? RemoteTmuxScreenTitleFilter()
        #expect(filter.filter(Data("next".utf8)) == Data("next".utf8))
    }

    /// A transport that keeps flooding makes the reader stop again while a catch-up is still
    /// waiting on tmux. That pause must not be lost: the output after the first catch-up's
    /// captures is just as stale, so a second catch-up starts when the first one finishes.
    @Test func aPauseDuringACatchUpStartsAnotherWhenItFinishes() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7))
        )
        var repaints = 0
        let token = fixture.connection.addObserver(onPaneSeed: { _, seed in
            if seed.restartsLiveStream { repaints += 1 }
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.requestCatchUpAfterFallingBehind()
        let queuedCommands = fixture.connection.pendingCommandKindsForTesting.count
        fixture.connection.requestCatchUpAfterFallingBehind()
        #expect(fixture.connection.pendingCommandKindsForTesting.count == queuedCommands)
        #expect(fixture.connection.catchUp.isRequested)

        finishPendingCommands(
            on: fixture.connection,
            captureRows: ["current screen"],
            paneHeight: 24,
            startingAt: 400
        )
        #expect(repaints == 2, "the pause during the first catch-up was dropped")
        #expect(!fixture.connection.catchUp.isRequested)
        #expect(!fixture.connection.catchUp.isRunning)
    }

    /// A catch-up's own capture replies can fill the read bound, so the reader pauses during the
    /// catch-up with no live output behind it. Once the reader has caught up before the catch-up
    /// ends, that pause must not start another catch-up: its captures would fill the bound again,
    /// and the cycle would repeat with nothing new to show.
    @Test func aPauseFromTheCatchUpsOwnRepliesDoesNotStartAnother() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7))
        )
        var repaints = 0
        let token = fixture.connection.addObserver(onPaneSeed: { _, seed in
            if seed.restartsLiveStream { repaints += 1 }
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.requestCatchUpAfterFallingBehind()
        // The capture replies fill the bound, then the parser works through them.
        fixture.connection.requestCatchUpAfterFallingBehind()
        fixture.connection.stdoutReaderCaughtUp()
        finishPendingCommands(
            on: fixture.connection,
            captureRows: ["current screen"],
            paneHeight: 24,
            startingAt: 400
        )

        #expect(repaints == 1, "a pause from the catch-up's own replies started another catch-up")
        #expect(!fixture.connection.catchUp.isRequested)
        #expect(!fixture.connection.catchUp.isRunning)
    }

    /// The last catch-up seed can also leave without finishing: its pane disappears and tmux
    /// answers the capture with "can't find pane". A pause kept during that catch-up still has
    /// to start the next one.
    @Test func aPauseDuringACatchUpSurvivesItsLastSeedFailing() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7))
        )
        fixture.connection.requestCatchUpAfterFallingBehind()
        fixture.connection.requestCatchUpAfterFallingBehind()
        let firstSeed = try #require(fixture.connection.pendingPaneSeeds[7]?.first?.id)
        let capture = try #require(fixture.connection.pendingCommandKindsForTesting.first {
            if case let .capturePane(paneId, token) = $0 { return paneId == 7 && token == firstSeed }
            return false
        })

        fixture.connection.failPaneSeedCommand(capture, errorLines: ["can't find pane: %7"])

        #expect(!fixture.connection.catchUp.isRequested, "the pause during the catch-up was dropped")
        let next = try #require(fixture.connection.pendingPaneSeeds[7]?.first)
        #expect(next.id != firstSeed)
        #expect(next.dropsPreCaptureOutput)
    }

    /// A reconnect seeds only a few panes at a time, so a pause during one finds panes still
    /// queued for their seed. Their backlog must not be drawn while they wait, and the seed they
    /// get drops their output up to its capture, as a catch-up seed does.
    @Test func aCatchUpDropsTheBacklogOfPanesQueuedForTheirReconnectSeed() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        let paneCount = RemoteTmuxControlConnection.maximumConcurrentReconnectPaneSeeds + 1
        fixture.connection.windowsByID = Dictionary(uniqueKeysWithValues: (1...paneCount).map {
            windowId in
            (
                windowId,
                RemoteTmuxWindow(
                    id: windowId,
                    width: 80,
                    height: 24,
                    layout: RemoteTmuxLayoutNode(
                        width: 80, height: 24, x: 0, y: 0, content: .pane(windowId + 10)
                    )
                )
            )
        })
        let queuedPane = paneCount + 10
        var rendered: [Int: Int] = [:]
        var seeds: [Int: RemoteTmuxPaneSeed] = [:]
        let token = fixture.connection.addObserver(
            onPaneOutput: { paneId, data in rendered[paneId, default: 0] += data.count },
            onPaneSeed: { paneId, seed in seeds[paneId] = seed }
        )
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.reseedAfterReconnect()
        #expect(fixture.connection.pendingReconnectPaneIDs == [queuedPane])
        fixture.connection.requestCatchUpAfterFallingBehind()
        #expect(fixture.connection.pendingPaneSeeds[queuedPane] == nil)
        #expect(fixture.connection.pendingReconnectPaneIDs == [queuedPane])

        fixture.connection.handleMessageForTesting(
            .output(paneId: queuedPane, data: Data("stale backlog".utf8))
        )
        #expect(rendered[queuedPane] == nil, "a pane queued for its reconnect seed drew the backlog")

        finishPendingCommands(
            on: fixture.connection,
            captureRows: ["current screen"],
            paneHeight: 24,
            startingAt: 400
        )
        let seed = try #require(seeds[queuedPane])
        #expect(seed.restartsLiveStream)
        #expect(seed.discardedOutput.isEmpty)
        #expect(Self.occurrences(of: "current screen", in: seed.snapshot) == 1)
        #expect(!fixture.connection.catchUp.isRunning)
        #expect(fixture.connection.pendingReconnectPaneIDs.isEmpty)
    }

    /// A pane whose seed already has its capture can't be covered by that capture: the output
    /// still in the stream is newer than it. The catch-up starts another capture behind it, so
    /// the backlog that arrives after the first seed finishes is dropped instead of drawn.
    @Test func aCatchUpRecapturesAPaneWhoseSeedAlreadyHasItsCapture() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7))
        )
        var rendered = 0
        var seeds: [RemoteTmuxPaneSeed] = []
        let token = fixture.connection.addObserver(
            onPaneOutput: { _, data in rendered += data.count },
            onPaneSeed: { _, seed in seeds.append(seed) }
        )
        defer { fixture.connection.removeObserver(token) }

        let firstSeed = try #require(fixture.connection.capturePane(paneId: 7, clearScrollback: true))
        finishPendingCommands(
            on: fixture.connection, captureRows: ["older screen"], paneHeight: 24, startingAt: 400,
            until: { fixture.connection.pendingPaneSeeds[7]?.first?.isCaptureInstalled == true }
        )
        fixture.connection.requestCatchUpAfterFallingBehind()
        #expect(fixture.connection.pendingPaneSeeds[7]?.count == 2, "the catch-up left the pane uncovered")

        finishPendingCommands(
            on: fixture.connection, captureRows: ["current screen"], paneHeight: 24, startingAt: 500,
            until: { fixture.connection.pendingPaneSeeds[7]?.first?.id != firstSeed }
        )
        fixture.connection.handleMessageForTesting(.output(paneId: 7, data: Data("stale backlog".utf8)))
        #expect(rendered == 0, "the backlog after the first seed was drawn")

        finishPendingCommands(
            on: fixture.connection, captureRows: ["current screen"], paneHeight: 24, startingAt: 600
        )
        #expect(seeds.count == 2)
        #expect(seeds.last?.restartsLiveStream == true)
        #expect(seeds.last.map { Self.occurrences(of: "current screen", in: $0.snapshot) } == 1)
        #expect(!fixture.connection.catchUp.isRunning)
    }

    /// A visible-only repaint captures the screen, not the lines a backlog pushed into history.
    /// When one is in progress as a catch-up starts, the backlog must stay dropped through that
    /// repaint, after its capture too, until a full-history capture behind it repaints the pane.
    @Test func aVisibleRepaintInACatchUpLeavesTheHistoryToAFullCapture() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(8))
        )
        var rendered = 0
        var seeds: [RemoteTmuxPaneSeed] = []
        let token = fixture.connection.addObserver(
            onPaneOutput: { _, data in rendered += data.count },
            onPaneSeed: { _, seed in seeds.append(seed) }
        )
        defer { fixture.connection.removeObserver(token) }

        let visibleSeed = try #require(fixture.connection.repaintPaneVisibleScreen(paneId: 8))
        fixture.connection.catchUpAfterFallingBehind()
        #expect(
            fixture.connection.pendingPaneSeeds[8]?.map(\.kind) == [.visibleRepaint, .fullHistory],
            "the catch-up left the pane's history to a visible-only capture"
        )

        finishPendingCommands(
            on: fixture.connection, captureRows: ["older screen"], paneHeight: 24, startingAt: 400,
            until: { fixture.connection.pendingPaneSeeds[8]?.first?.isCaptureInstalled == true }
        )
        fixture.connection.handleMessageForTesting(.output(paneId: 8, data: Data("backlog\r\n".utf8)))
        finishPendingCommands(
            on: fixture.connection, captureRows: ["older screen"], paneHeight: 24, startingAt: 500,
            until: { fixture.connection.pendingPaneSeeds[8]?.first?.id != visibleSeed }
        )
        fixture.connection.handleMessageForTesting(.output(paneId: 8, data: Data("backlog\r\n".utf8)))
        #expect(rendered == 0, "the backlog after the visible capture was drawn")
        #expect(seeds.first?.catchUpOutput.isEmpty == true)

        finishPendingCommands(
            on: fixture.connection, captureRows: ["current screen"], paneHeight: 24, startingAt: 600
        )
        #expect(seeds.map(\.kind) == [.visibleRepaint, .fullHistory])
        #expect(seeds.last?.restartsLiveStream == true)
        #expect(!fixture.connection.catchUp.isRunning)
    }

    /// A budget recovery drops the output a pane's seed retained, and the live escape filters
    /// never saw it. The seed that replaces it must restart them: a filter left inside a title
    /// would swallow the pane's next output as title text.
    @Test func aSeedAfterABudgetRecoveryRestartsTheLiveEscapeFilters() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7))
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = manager.selectedWorkspace!
        workspace.isRemoteTmuxMirror = true
        let sessionMirror = RemoteTmuxSessionMirror(
            host: fixture.connection.host,
            sessionName: "work",
            connection: fixture.connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }
        var seeds: [RemoteTmuxPaneSeed] = []
        let token = fixture.connection.addObserver(onPaneSeed: { _, seed in seeds.append(seed) })
        defer { fixture.connection.removeObserver(token) }

        // The last routed output opened a screen title. The bytes that close it are retained by
        // a repaint, then dropped with it when the pane runs past its live-byte budget.
        fixture.connection.handleMessageForTesting(.output(paneId: 7, data: Data("\u{1b}kvim".utf8)))
        _ = try #require(fixture.connection.repaintPaneVisibleScreen(paneId: 7))
        fixture.connection.handleMessageForTesting(.output(paneId: 7, data: Data("\u{1b}\\".utf8)))
        fixture.connection.handleMessageForTesting(.output(
            paneId: 7,
            data: Data(
                repeating: UInt8(ascii: "x"),
                count: RemoteTmuxControlConnection.maximumPendingPaneSeedLiveBytes
            )
        ))
        #expect(fixture.connection.pendingPaneSeeds[7] == nil)
        #expect(fixture.connection.snapshot().recentEvents.contains { $0.hasPrefix("pane-seed-backpressure") })

        // The replacement seed, started the way the deferred recovery starts it.
        _ = try #require(fixture.connection.seedPane(paneId: 7, clearScrollback: true))
        finishPendingCommands(
            on: fixture.connection, captureRows: ["screen"], paneHeight: 24, startingAt: 400
        )
        #expect(seeds.last?.restartsLiveStream == true)
        var filter = sessionMirror.titleFilters[7] ?? RemoteTmuxScreenTitleFilter()
        #expect(filter.filter(Data("next".utf8)) == Data("next".utf8))
    }
}
