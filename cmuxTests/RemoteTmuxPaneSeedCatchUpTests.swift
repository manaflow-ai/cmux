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
    /// seed, and a pane already being repainted joins the catch-up instead of seeding twice.
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
        #expect(fixture.connection.pendingPaneSeeds[8]?.count == 1)
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
        #expect(!fixture.connection.isCatchingUpAfterFallingBehind)

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
        #expect(fixture.connection.catchUpRequested)

        finishPendingCommands(
            on: fixture.connection,
            captureRows: ["current screen"],
            paneHeight: 24,
            startingAt: 400
        )
        #expect(repaints == 2, "the pause during the first catch-up was dropped")
        #expect(!fixture.connection.catchUpRequested)
        #expect(!fixture.connection.isCatchingUpAfterFallingBehind)
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

        #expect(!fixture.connection.catchUpRequested, "the pause during the catch-up was dropped")
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
        #expect(!fixture.connection.isCatchingUpAfterFallingBehind)
        #expect(fixture.connection.pendingReconnectPaneIDs.isEmpty)
    }
}
