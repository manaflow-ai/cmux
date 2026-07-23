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

/// Regression coverage for transport-independent remote-tmux seed cutover.
///
/// Tailscale SSH changes read latency and chunk boundaries, but preserves byte
/// order. These tests therefore feed the real control parser in deliberately
/// uneven chunks and assert at the connection observer boundary: output already
/// represented by `capture-pane` must not escape ahead of the seed, while output
/// after the capture block must be replayed exactly once after pane state.
@MainActor
@Suite struct RemoteTmuxPaneSeedTransportTests {
    @Test func laggingControlOutputCursorCannotReplayCapturedReconnectOutput() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var rendered = Data()
        let token = fixture.connection.addObserver(onPaneOutput: { paneID, data in
            guard paneID == 7 else { return }
            rendered.append(data)
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 7)
        let commands = String(decoding: fixture.pipe.fileHandleForReading.availableData, as: UTF8.self)

        // Model tmux's pane grid and this control client's output cursor as
        // separate authorities. On reconnect the grid may already contain a
        // record while the client's cursor still owes its `%output`. Without a
        // server-side cursor reset, transport latency can deliver that stale
        // notification after capture even though capture already painted it.
        let pauseRange = try #require(
            commands.range(of: "refresh-client -A \"%7:pause\"")
        )
        let captureRange = try #require(commands.range(of: "capture-pane "))
        let stateRange = try #require(commands.range(of: "cursor_x=#{cursor_x}"))
        let continueRange = try #require(
            commands.range(of: "refresh-client -A \"%7:continue\"")
        )
        #expect(pauseRange.lowerBound < captureRange.lowerBound)
        #expect(captureRange.lowerBound < stateRange.lowerBound)
        #expect(stateRange.lowerBound < continueRange.lowerBound)
        #expect(!commands.contains("refresh-client -A \"%7:off\" -A \"%7:on\""))
        let marker = "AUTORECONNECT_STREAM_29"
        var stream = Data()
        var commandNumber = 20
        for kind in fixture.connection.pendingCommandKindsForTesting {
            let lines: [String]
            switch kind {
            case .paneAltScreen:
                lines = ["0"]
            case .capturePane:
                lines = ["before", marker, "after"]
            case .paneState:
                lines = [Self.paneStateLine(cursorX: 5, cursorY: 2)]
            default:
                lines = []
            }
            stream.append(Self.commandResultBlock(number: commandNumber, lines: lines))
            commandNumber += 1
        }
        deliverRechunked(stream, to: fixture.connection)

        #expect(Self.occurrences(of: marker, in: rendered) == 1)
    }

    @Test func reconnectReadyWaitsForEveryPaneSeedToFinish() {
        let fixture = attachedConnection()
        defer { fixture.close() }

        fixture.connection.pendingAttachRedrawKick = false
        fixture.connection.windowsByID = [
            1: RemoteTmuxWindow(
                id: 1,
                width: 80,
                height: 24,
                layout: RemoteTmuxLayoutNode(
                    width: 80, height: 24, x: 0, y: 0, content: .pane(7)
                )
            ),
            2: RemoteTmuxWindow(
                id: 2,
                width: 80,
                height: 24,
                layout: RemoteTmuxLayoutNode(
                    width: 80, height: 24, x: 0, y: 0, content: .pane(8)
                )
            ),
        ]

        var reconnectReadyCount = 0
        let token = fixture.connection.addObserver(
            onReconnectReady: { reconnectReadyCount += 1 }
        )
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.reseedAfterReconnect()
        #expect(reconnectReadyCount == 0)

        var finishedPaneSeeds = 0
        var commandNumber = 30
        while let kind = fixture.connection.pendingCommandKindsForTesting.first {
            let lines: [String]
            switch kind {
            case .paneReflow:
                lines = ["0|zsh"]
            case .paneAltScreen:
                lines = ["0"]
            case .capturePane:
                lines = ["prompt", "❯"]
            case .paneState:
                lines = [Self.paneStateLine(cursorX: 1, cursorY: 1)]
            case .panePath:
                lines = ["/tmp"]
            default:
                lines = []
            }
            fixture.connection.handleMessageForTesting(
                .commandResult(commandNumber: commandNumber, lines: lines, isError: false)
            )
            commandNumber += 1
            if case .paneState = kind {
                finishedPaneSeeds += 1
                if finishedPaneSeeds < 2 {
                    #expect(reconnectReadyCount == 0)
                }
            }
        }

        #expect(finishedPaneSeeds == 2)
        #expect(reconnectReadyCount == 1)
    }

    @Test func reconnectReseedLimitsConcurrentPaneSnapshots() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        fixture.connection.windowsByID = Dictionary(uniqueKeysWithValues: (1...5).map {
            windowID in
            (
                windowID,
                RemoteTmuxWindow(
                    id: windowID,
                    width: 80,
                    height: 24,
                    layout: RemoteTmuxLayoutNode(
                        width: 80,
                        height: 24,
                        x: 0,
                        y: 0,
                        content: .pane(windowID + 10)
                    )
                )
            )
        })

        fixture.connection.reseedAfterReconnect()
        #expect(fixture.connection.pendingReconnectSeedIDs.count == 2)
        #expect(fixture.connection.pendingPaneSeeds.count == 2)

        let firstPaneID = try #require(fixture.connection.pendingPaneSeeds.keys.min())
        let firstSeedID = try #require(
            fixture.connection.pendingPaneSeeds[firstPaneID]?.first?.id
        )
        fixture.connection.cancelPaneSeed(paneId: firstPaneID, seedID: firstSeedID)

        #expect(fixture.connection.pendingReconnectSeedIDs.count == 2)
        #expect(fixture.connection.pendingPaneSeeds.count == 2)
        #expect(fixture.connection.pendingPaneSeeds[firstPaneID] == nil)
    }

    @Test func reconnectReseedDeDuplicatesTransientPaneOwnership() {
        let fixture = attachedConnection()
        defer { fixture.close() }

        let sharedPane = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0, content: .pane(17)
        )
        fixture.connection.windowsByID = [
            1: RemoteTmuxWindow(id: 1, width: 80, height: 24, layout: sharedPane),
            2: RemoteTmuxWindow(id: 2, width: 80, height: 24, layout: sharedPane),
        ]

        fixture.connection.reseedAfterReconnect()

        #expect(fixture.connection.pendingReconnectSeedIDs.count == 1)
        #expect(fixture.connection.pendingReconnectPaneIDs.isEmpty)
        #expect(fixture.connection.pendingPaneSeeds[17]?.count == 1)
    }

    @Test func pruningFinalReconnectSeedNotifiesReadyOnce() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID = [
            1: RemoteTmuxWindow(
                id: 1,
                width: 80,
                height: 24,
                layout: RemoteTmuxLayoutNode(
                    width: 80, height: 24, x: 0, y: 0, content: .pane(7)
                )
            ),
        ]

        var reconnectReadyCount = 0
        let token = fixture.connection.addObserver(
            onReconnectReady: { reconnectReadyCount += 1 }
        )
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.reseedAfterReconnect()
        _ = try #require(fixture.connection.pendingPaneSeeds[7]?.first)
        fixture.connection.discardPendingPaneSeeds(paneId: 7)

        #expect(reconnectReadyCount == 1)
    }

    @Test func parserValidLargeSeedWaitsForGridWithoutReconnecting() {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(
                width: 80, height: 24, x: 0, y: 0, content: .pane(7)
            )
        )
        fixture.connection.windowOrder = [1]
        fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])

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

        let snapshot = Data(repeating: UInt8(ascii: "x"), count: 9 * 1_024 * 1_024)
        sessionMirror.routeSeed(
            paneId: 7,
            seed: RemoteTmuxPaneSeed(
                kind: .fullHistory,
                discardedOutput: [],
                snapshot: snapshot,
                catchUpOutput: [],
                state: Data()
            )
        )

        #expect(fixture.connection.connectionState == .connected)
        #expect(sessionMirror.pendingPaneSeedByteCounts[7] == snapshot.count)
    }

    @Test func stalledGridDropsBytesAndRetainsPaneLocalFrameDemand() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(
                width: 80, height: 24, x: 0, y: 0, content: .pane(7)
            )
        )
        fixture.connection.windowOrder = [1]
        fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])

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

        sessionMirror.routeSeed(
            paneId: 7,
            seed: RemoteTmuxPaneSeed(
                kind: .fullHistory,
                discardedOutput: [],
                snapshot: Data("authoritative".utf8),
                catchUpOutput: [],
                state: Data()
            )
        )
        let deadlineID = try #require(sessionMirror.pendingPaneSeedDeadlineIDs[7])
        sessionMirror.expirePendingPaneSeedDelivery(paneId: 7, deadlineID: deadlineID)

        #expect(fixture.connection.connectionState == .connected)
        #expect(sessionMirror.pendingPaneSeedBytes[7] == nil)
        #expect(sessionMirror.pendingPaneSeedByteCounts[7] == nil)
        #expect(sessionMirror.pendingPaneSeedTotalByteCount == 0)
        #expect(sessionMirror.deferredFullPaneReseeds == [7])
        #expect(sessionMirror.paneSeedFrameDemandReleases[7] != nil)
        #expect(!sessionMirror.paneSeedReadinessObserverTokens.isEmpty)
        let panelID = try #require(sessionMirror.panelIdByPane[7])
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        #expect(panel.hostedView.surfaceView.localRenderedFrameNotificationDemandIsActive)
    }

    @Test func staleDeliveryDeadlineCannotExpireReplacementSeed() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(
                width: 80, height: 24, x: 0, y: 0, content: .pane(7)
            )
        )
        fixture.connection.windowOrder = [1]
        fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let sessionMirror = RemoteTmuxSessionMirror(
            host: fixture.connection.host,
            sessionName: "work",
            connection: fixture.connection,
            tabManager: manager,
            workspace: manager.selectedWorkspace!
        )
        defer { sessionMirror.detachObserver() }

        sessionMirror.routeSeed(
            paneId: 7,
            seed: RemoteTmuxPaneSeed(
                kind: .fullHistory,
                discardedOutput: [], snapshot: Data("first".utf8),
                catchUpOutput: [], state: Data()
            )
        )
        let firstDeadlineID = try #require(sessionMirror.pendingPaneSeedDeadlineIDs[7])
        sessionMirror.routeSeed(
            paneId: 7,
            seed: RemoteTmuxPaneSeed(
                kind: .fullHistory,
                discardedOutput: [], snapshot: Data("replacement".utf8),
                catchUpOutput: [], state: Data()
            )
        )
        let replacementDeadlineID = try #require(
            sessionMirror.pendingPaneSeedDeadlineIDs[7]
        )
        #expect(firstDeadlineID != replacementDeadlineID)

        sessionMirror.expirePendingPaneSeedDelivery(
            paneId: 7,
            deadlineID: firstDeadlineID
        )

        #expect(sessionMirror.pendingPaneSeedBytes[7] != nil)
        #expect(sessionMirror.pendingPaneSeedDeadlineIDs[7] == replacementDeadlineID)
        #expect(sessionMirror.deferredFullPaneReseeds.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func lateGridAfterExpiredFullAndVisibleRepaintRequestsOneFullRecovery() async throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: RemoteTmuxLayoutNode(
                width: 80, height: 24, x: 0, y: 0, content: .pane(7)
            )
        )
        fixture.connection.windowOrder = [1]
        fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let sessionMirror = RemoteTmuxSessionMirror(
            host: fixture.connection.host,
            sessionName: "work",
            connection: fixture.connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }
        let panelID = try #require(sessionMirror.panelIdByPane[7])
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let terminal = try hostedTerminal(panel.surface)
        defer { terminal.window.orderOut(nil) }
        await waitForLiveSurface(terminal.surface)
        finishPendingCommands(
            on: fixture.connection,
            captureRows: ["initial"],
            paneHeight: 24,
            startingAt: 200
        )
        sessionMirror.clearPendingPaneSeedDeliveries()

        terminal.surface.setAssignedGrid(columns: 40, rows: 12)
        await waitForAppliedTerminalGrid(terminal.surface, columns: 40, rows: 12)

        sessionMirror.routeSeed(
            paneId: 7,
            seed: RemoteTmuxPaneSeed(
                kind: .fullHistory,
                discardedOutput: [], snapshot: Data("full-a".utf8),
                catchUpOutput: [], state: Data()
            )
        )
        let deadlineID = try #require(sessionMirror.pendingPaneSeedDeadlineIDs[7])
        sessionMirror.expirePendingPaneSeedDelivery(paneId: 7, deadlineID: deadlineID)
        #expect(sessionMirror.deferredFullPaneReseeds == [7])

        sessionMirror.routeSeed(
            paneId: 7,
            seed: RemoteTmuxPaneSeed(
                kind: .visibleRepaint,
                discardedOutput: [], snapshot: Data("visible-b".utf8),
                catchUpOutput: [], state: Data()
            )
        )
        #expect(sessionMirror.deferredFullPaneReseeds == [7])
        #expect(sessionMirror.pendingPaneSeedBytes[7] == nil)
        #expect(terminal.surface.hostedView.surfaceView.localRenderedFrameNotificationDemandIsActive)

        // The real terminal grid applies asynchronously after the request-time
        // callback. Remove that callback so only the pane-local rendered-frame
        // path can discover readiness and request recovery. XCTest windows can
        // be WindowServer-occluded even after `makeKeyAndOrderFront`, so inject
        // the exact view callback the Metal layer delivers instead of depending
        // on a nondeterministic drawable being vended by the test process.
        terminal.surface.onManualSizeApplied = nil
        terminal.surface.setAssignedGrid(columns: 80, rows: 24)
        await waitForAppliedTerminalGridUsingTicks(
            terminal.surface,
            columns: 80,
            rows: 24
        )
        NotificationCenter.default.post(
            name: .ghosttyDidRenderFrame,
            object: terminal.surface.hostedView.surfaceView
        )

        #expect(sessionMirror.deferredFullPaneReseeds.isEmpty)
        #expect(
            fixture.connection.pendingPaneSeeds[7]?.filter {
                $0.kind == .fullHistory
            }.count == 1
        )
        #expect(!terminal.surface.hostedView.surfaceView.localRenderedFrameNotificationDemandIsActive)

        finishPendingCommands(
            on: fixture.connection,
            captureRows: ["full-c"],
            paneHeight: 24,
            startingAt: 300
        )
        #expect(fixture.connection.pendingPaneSeeds[7] == nil)
        #expect(sessionMirror.pendingPaneSeedBytes[7] == nil)
        #expect(!terminal.surface.hostedView.surfaceView.localRenderedFrameNotificationDemandIsActive)
    }

    @Test func aggregateConnectionSeedBudgetReconnectsAndReleasesBytes() throws {
        let fixture = attachedConnection(pendingPaneSeedByteLimit: 5)
        defer { fixture.close() }
        _ = try #require(
            fixture.connection.beginPaneSeed(
                paneId: 7,
                clearScrollback: false,
                kind: .fullHistory
            )
        )

        #expect(fixture.connection.absorbPaneOutputIntoPendingSeed(
            paneId: 7,
            data: Data("abc".utf8)
        ))
        #expect(fixture.connection.pendingPaneSeedByteCount == 3)
        _ = try #require(
            fixture.connection.beginPaneSeed(
                paneId: 8,
                clearScrollback: false,
                kind: .fullHistory
            )
        )
        #expect(fixture.connection.absorbPaneOutputIntoPendingSeed(
            paneId: 8,
            data: Data("def".utf8)
        ))

        #expect(fixture.connection.connectionState == .reconnecting)
        #expect(fixture.connection.pendingPaneSeedByteCount == 0)
        #expect(fixture.connection.pendingPaneSeeds.isEmpty)
    }

    @Test func connectionSeedCountersReleaseOnFinishPruneAndDisconnect() throws {
        let fixture = attachedConnection(pendingPaneSeedByteLimit: 32)
        defer { fixture.close() }

        let finishedID = try #require(fixture.connection.beginPaneSeed(
            paneId: 7,
            clearScrollback: false,
            kind: .fullHistory
        ))
        #expect(fixture.connection.absorbPaneOutputIntoPendingSeed(
            paneId: 7,
            data: Data("finish".utf8)
        ))
        fixture.connection.finishPaneSeed(paneId: 7, seedID: finishedID, state: Data())
        #expect(fixture.connection.pendingPaneSeedByteCount == 0)

        _ = try #require(fixture.connection.beginPaneSeed(
            paneId: 8,
            clearScrollback: false,
            kind: .fullHistory
        ))
        #expect(fixture.connection.absorbPaneOutputIntoPendingSeed(
            paneId: 8,
            data: Data("prune".utf8)
        ))
        fixture.connection.discardPendingPaneSeeds(keeping: [])
        #expect(fixture.connection.pendingPaneSeedByteCount == 0)

        _ = try #require(fixture.connection.beginPaneSeed(
            paneId: 9,
            clearScrollback: false,
            kind: .fullHistory
        ))
        #expect(fixture.connection.absorbPaneOutputIntoPendingSeed(
            paneId: 9,
            data: Data("disconnect".utf8)
        ))
        fixture.connection.beginReconnecting()
        #expect(fixture.connection.pendingPaneSeedByteCount == 0)
        #expect(fixture.connection.pendingPaneSeeds.isEmpty)
    }

    @Test func aggregateConsumerBudgetRecoversOnlyOverflowingPane() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            width: 1_001,
            height: 500,
            layout: RemoteTmuxLayoutNode(
                width: 1_001,
                height: 500,
                x: 0,
                y: 0,
                content: .horizontal([
                    RemoteTmuxLayoutNode(
                        width: 500, height: 500, x: 0, y: 0, content: .pane(7)
                    ),
                    RemoteTmuxLayoutNode(
                        width: 500, height: 500, x: 501, y: 0, content: .pane(8)
                    ),
                ])
            )
        )
        fixture.connection.windowOrder = [1]
        fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7, 8])

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let sessionMirror = RemoteTmuxSessionMirror(
            host: fixture.connection.host,
            sessionName: "work",
            connection: fixture.connection,
            tabManager: manager,
            workspace: manager.selectedWorkspace!,
            pendingPaneSeedByteLimit: 10
        )
        defer { sessionMirror.detachObserver() }

        sessionMirror.routeSeed(
            paneId: 7,
            seed: RemoteTmuxPaneSeed(
                kind: .fullHistory,
                discardedOutput: [], snapshot: Data("123456".utf8),
                catchUpOutput: [], state: Data()
            )
        )
        #expect(sessionMirror.pendingPaneSeedByteCounts[7] == 6)
        #expect(sessionMirror.pendingPaneSeedTotalByteCount == 6)

        sessionMirror.routeSeed(
            paneId: 8,
            seed: RemoteTmuxPaneSeed(
                kind: .fullHistory,
                discardedOutput: [], snapshot: Data("abcdef".utf8),
                catchUpOutput: [], state: Data()
            )
        )

        #expect(fixture.connection.connectionState == .connected)
        #expect(Set(sessionMirror.pendingPaneSeedBytes.keys) == [7])
        #expect(sessionMirror.pendingPaneSeedByteCounts[7] == 6)
        #expect(sessionMirror.pendingPaneSeedByteCounts[8] == nil)
        #expect(sessionMirror.pendingPaneSeedTotalByteCount == 6)
        #expect(sessionMirror.deferredFullPaneReseeds == [8])

        sessionMirror.reconcilePendingPaneSeedDeliveries(keeping: [8])
        #expect(sessionMirror.pendingPaneSeedTotalByteCount == 0)
        #expect(sessionMirror.pendingPaneSeedByteCounts.isEmpty)
        #expect(sessionMirror.deferredFullPaneReseeds == [8])

        sessionMirror.clearPendingPaneSeedDeliveries()
        #expect(sessionMirror.paneSeedFrameDemandReleases.isEmpty)
    }

    @Test func pendingSeedCoalescesTinyLiveOutputChunks() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        let seedID = try #require(
            fixture.connection.beginPaneSeed(
                paneId: 7,
                clearScrollback: true,
                kind: .fullHistory
            )
        )
        for _ in 0..<10_000 {
            #expect(
                fixture.connection.absorbPaneOutputIntoPendingSeed(
                    paneId: 7,
                    data: Data([UInt8(ascii: "x")])
                )
            )
        }

        let pending = fixture.connection.pendingPaneSeeds[7]?.first
        #expect(pending?.id == seedID)
        #expect(pending?.bufferedLiveByteCount == 10_000)
        #expect(pending?.discardedOutput.count == 1)
    }

    @Test func outputCursorResetFailureReconnectsWithoutReplayingBacklog() {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var rendered = Data()
        let token = fixture.connection.addObserver(onPaneOutput: { _, data in
            rendered.append(data)
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 7)
        fixture.connection.handleMessageForTesting(.output(paneId: 7, data: Data("stale".utf8)))
        fixture.connection.handleMessageForTesting(
            .commandResult(commandNumber: 40, lines: ["reset failed"], isError: true)
        )

        #expect(fixture.connection.connectionState == .reconnecting)
        #expect(fixture.connection.pendingPaneSeeds.isEmpty)
        #expect(rendered.isEmpty)
    }

    @Test func captureFailureAfterCursorResetReconnectsWithoutReplayingBacklog() {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var rendered = Data()
        let token = fixture.connection.addObserver(onPaneOutput: { _, data in
            rendered.append(data)
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 7)
        fixture.connection.handleMessageForTesting(.output(paneId: 7, data: Data("stale".utf8)))
        fixture.connection.handleMessageForTesting(
            .commandResult(commandNumber: 41, lines: [], isError: false)
        )
        fixture.connection.handleMessageForTesting(
            .commandResult(commandNumber: 42, lines: ["0"], isError: false)
        )
        fixture.connection.handleMessageForTesting(
            .commandResult(commandNumber: 43, lines: ["capture failed"], isError: true)
        )

        #expect(fixture.connection.connectionState == .reconnecting)
        #expect(fixture.connection.pendingPaneSeeds.isEmpty)
        #expect(rendered.isEmpty)
    }

    @Test func outputContinueFailureReconnectsAfterSeedCompletion() {
        let fixture = attachedConnection()
        defer { fixture.close() }

        fixture.connection.capturePane(paneId: 7)
        fixture.connection.handleMessageForTesting(
            .commandResult(commandNumber: 41, lines: [], isError: false)
        )
        fixture.connection.handleMessageForTesting(
            .commandResult(commandNumber: 42, lines: ["0"], isError: false)
        )
        fixture.connection.handleMessageForTesting(
            .commandResult(commandNumber: 43, lines: ["authoritative"], isError: false)
        )
        fixture.connection.handleMessageForTesting(
            .commandResult(
                commandNumber: 44,
                lines: [Self.paneStateLine(cursorX: 3, cursorY: 1)],
                isError: false
            )
        )
        #expect(fixture.connection.pendingPaneSeeds.isEmpty)

        fixture.connection.handleMessageForTesting(
            .commandResult(commandNumber: 45, lines: ["continue failed"], isError: true)
        )

        #expect(fixture.connection.connectionState == .reconnecting)
    }

    @Test func captureFailureForExitedPaneCancelsSeedWithoutReconnect() {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var rendered = Data()
        let token = fixture.connection.addObserver(onPaneOutput: { _, data in
            rendered.append(data)
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 7)
        fixture.connection.handleMessageForTesting(
            .output(paneId: 7, data: Data("stale".utf8))
        )
        fixture.connection.handleMessageForTesting(
            .commandResult(commandNumber: 40, lines: [], isError: false)
        )
        fixture.connection.handleMessageForTesting(
            .commandResult(commandNumber: 41, lines: ["0"], isError: false)
        )
        fixture.connection.handleMessageForTesting(
            .commandResult(
                commandNumber: 42,
                lines: ["can't find pane: %7"],
                isError: true
            )
        )

        #expect(fixture.connection.connectionState == .connected)
        #expect(fixture.connection.pendingPaneSeeds.isEmpty)
        #expect(rendered.isEmpty)
    }

    @Test func rechunkedLiveEchoCutsOverAtomicallyAtCaptureReply() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var writes: [Data] = []
        let token = fixture.connection.addObserver(onPaneOutput: { paneID, data in
            guard paneID == 7 else { return }
            writes.append(data)
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 7)

        let paneState = Self.paneStateLine(cursorX: 10, cursorY: 1)
        deliverRechunked(
            Self.seedRaceStream(
                preCaptureOutput: "hostname",
                capturedRows: ["prompt", "❯ hostname"],
                postCaptureOutput: "\\015\\012nuc-14-pro",
                paneState: paneState
            ),
            to: fixture.connection
        )

        var expected = RemoteTmuxControlConnection.altScreenExitSequence
        expected.append(Data("\u{1b}[H\u{1b}[2Jprompt\r\n❯ hostname".utf8))
        expected.append(
            RemoteTmuxControlMessageDecoding().paneStateSeedSequence(from: paneState)
        )
        expected.append(Data("\r\nnuc-14-pro".utf8))

        #expect(writes == [expected])
    }

    @Test func titleEscapeSplitAcrossSnapshotBoundaryCannotConsumeSeed() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var filter = RemoteTmuxScreenTitleFilter()
        var rendered = Data()
        let token = fixture.connection.addObserver(onPaneOutput: { paneID, data in
            guard paneID == 9 else { return }
            rendered.append(filter.filter(data))
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 9)

        let paneState = Self.paneStateLine(cursorX: 1, cursorY: 0)
        deliverRechunked(
            Self.seedRaceStream(
                // A screen/tmux title escape may itself cross `%output` records.
                // The snapshot is authoritative terminal content, not a
                // continuation of this incomplete live escape.
                preCaptureOutput: "\\033kremote-title",
                capturedRows: ["dir git:main", "❯"],
                postCaptureOutput: "\\033\\134x",
                paneState: paneState,
                paneID: 9
            ),
            to: fixture.connection
        )

        var unfilteredSeed = RemoteTmuxControlConnection.altScreenExitSequence
        unfilteredSeed.append(Data("\u{1b}[H\u{1b}[2Jdir git:main\r\n❯".utf8))
        unfilteredSeed.append(
            RemoteTmuxControlMessageDecoding().paneStateSeedSequence(from: paneState)
        )
        unfilteredSeed.append(Data("\u{1b}\\x".utf8))
        var cleanBoundaryFilter = RemoteTmuxScreenTitleFilter()
        let expected = cleanBoundaryFilter.filter(unfilteredSeed)

        #expect(rendered == expected)
        #expect(String(decoding: rendered, as: UTF8.self).contains("dir git:main"))
    }

    @Test func seedAwareObserverReceivesTypedCutoverWithoutCompatibilityWrite() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var liveWrites: [Data] = []
        var seeds: [RemoteTmuxPaneSeed] = []
        let token = fixture.connection.addObserver(
            onPaneOutput: { paneID, data in
                guard paneID == 5 else { return }
                liveWrites.append(data)
            },
            onPaneSeed: { paneID, seed in
                guard paneID == 5 else { return }
                seeds.append(seed)
            }
        )
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 5)
        let paneState = Self.paneStateLine(cursorX: 3, cursorY: 2)
        deliverRechunked(
            Self.seedRaceStream(
                preCaptureOutput: "before-capture",
                capturedRows: ["authoritative"],
                postCaptureOutput: "after-capture",
                paneState: paneState,
                paneID: 5
            ),
            to: fixture.connection
        )

        let seed = try #require(seeds.first)
        #expect(seeds.count == 1)
        #expect(liveWrites.isEmpty)
        #expect(seed.kind == .fullHistory)
        #expect(seed.discardedOutput == [Data("before-capture".utf8)])
        #expect(seed.catchUpOutput == [Data("after-capture".utf8)])

        var snapshot = RemoteTmuxControlConnection.altScreenExitSequence
        snapshot.append(Data("\u{1b}[H\u{1b}[2Jauthoritative".utf8))
        #expect(seed.snapshot == snapshot)
        #expect(
            seed.state
                == RemoteTmuxControlMessageDecoding().paneStateSeedSequence(from: paneState)
        )
    }

    /// A full-history seed is a replacement, not an append. A first paint can
    /// reach local scrollback before a newer authoritative capture finishes;
    /// replaying the newer capture must remove that older copy.
    @Test(.timeLimit(.minutes(1)))
    func successiveFullHistorySeedReplacesPreviouslyRenderedPrefix() async throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        let layout = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0, content: .pane(7)
        )
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1, name: "main", width: 80, height: 24, layout: layout
        )
        fixture.connection.windowOrder = [1]
        fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let sessionMirror = RemoteTmuxSessionMirror(
            host: fixture.connection.host,
            sessionName: "work",
            connection: fixture.connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }
        let panelID = try #require(sessionMirror.panelIdByPane[7])
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let terminal = try hostedTerminal(panel.surface)
        defer { terminal.window.orderOut(nil) }
        await waitForLiveSurface(terminal.surface)
        terminal.surface.setAssignedGrid(columns: 80, rows: 24)
        await waitForAppliedTerminalGrid(terminal.surface, columns: 80, rows: 24)

        finishPendingCommands(
            on: fixture.connection,
            captureRows: ["FIRST-PAINT"],
            paneHeight: 24,
            startingAt: 20
        )

        let prefix = [
            "SEED-BEGIN",
            "seed-001: plain",
            "",
            "seed-003: after-blank",
            "seed-esc: RED | BOLD | UNDER",
        ]
        let liveRows = prefix + (1...40).map { String(format: "BEFORE-RESEED-%03d", $0) }
        fixture.connection.routePaneOutput(
            paneId: 7,
            data: Data((liveRows.joined(separator: "\r\n") + "\r\n").utf8)
        )
        await waitForTerminalText(terminal.surface) { $0.contains("BEFORE-RESEED-040") }

        let authoritativeRows = prefix + [
            "seed-unicode: αβγ 你好 🚀 é",
            "seed-tabs: A\tB\tC",
            "SEED-END",
        ]
        #expect(fixture.connection.seedPane(paneId: 7) != nil)
        finishPendingCommands(
            on: fixture.connection,
            captureRows: authoritativeRows,
            paneHeight: 24,
            startingAt: 60
        )
        await waitForTerminalText(terminal.surface) { $0.contains("SEED-END") }

        let rendered = try readFullTerminalText(terminal.surface)
        for marker in prefix where !marker.isEmpty {
            #expect(
                rendered.components(separatedBy: marker).count - 1 == 1,
                "a replacement full-history seed must leave exactly one copy of \(marker)"
            )
        }
    }

    /// Catch-up bytes continue from the cursor represented by the authoritative
    /// snapshot boundary. Restoring that cursor after catch-up can concatenate
    /// two server rows even though both marker payloads survive.
    @Test(.timeLimit(.minutes(1)))
    func paneSeedRestoresBoundaryCursorBeforeCatchUpOutput() async throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        let layout = RemoteTmuxLayoutNode(
            width: 94, height: 24, x: 0, y: 0, content: .pane(7)
        )
        fixture.connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1, name: "main", width: 94, height: 24, layout: layout
        )
        fixture.connection.windowOrder = [1]
        fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let sessionMirror = RemoteTmuxSessionMirror(
            host: fixture.connection.host,
            sessionName: "work",
            connection: fixture.connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }
        let panelID = try #require(sessionMirror.panelIdByPane[7])
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let terminal = try hostedTerminal(panel.surface)
        defer { terminal.window.orderOut(nil) }
        await waitForLiveSurface(terminal.surface)
        terminal.surface.setAssignedGrid(columns: 94, rows: 24)
        await waitForAppliedTerminalGrid(terminal.surface, columns: 94, rows: 24)
        finishPendingCommands(
            on: fixture.connection,
            captureRows: [],
            paneHeight: 24,
            startingAt: 20
        )

        let boundaryState = RemoteTmuxControlMessageDecoding().paneStateSeedSequence(
            from: Self.paneStateLine(cursorX: 0, cursorY: 1, paneHeight: 24)
        )
        sessionMirror.routeSeed(
            paneId: 7,
            seed: RemoteTmuxPaneSeed(
                kind: .fullHistory,
                discardedOutput: [],
                snapshot: Data("\u{1b}[H\u{1b}[2J\u{1b}[3JRUN-0034".utf8),
                catchUpOutput: [Data("RUN-0035\r\n".utf8)],
                state: boundaryState
            )
        )
        await waitForTerminalText(terminal.surface) { $0.contains("RUN-0035") }

        let rows = try readFullTerminalText(terminal.surface)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let markerRows = rows.filter { $0.contains("RUN-0034") || $0.contains("RUN-0035") }
        #expect(markerRows == ["RUN-0034", "RUN-0035"])
    }

    @Test func visibleRepaintMatchesAlternateScreenBeforeCapturePaint() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var seeds: [RemoteTmuxPaneSeed] = []
        let token = fixture.connection.addObserver(
            onPaneSeed: { paneID, seed in
                guard paneID == 7 else { return }
                seeds.append(seed)
            }
        )
        defer { fixture.connection.removeObserver(token) }

        for (iteration, alternateOn) in ["1", "0"].enumerated() {
            fixture.connection.repaintPaneVisibleScreen(paneId: 7)
            var stream = Data()
            var commandNumber = 60 + iteration * 10
            for kind in fixture.connection.pendingCommandKindsForTesting {
                let lines: [String]
                switch kind {
                case .paneAltScreen:
                    lines = [alternateOn]
                case .capturePane:
                    lines = [iteration == 0 ? "ALT_SCREEN" : "PRIMARY_SCREEN"]
                case .paneState:
                    lines = [Self.paneStateLine(cursorX: 0, cursorY: 0)]
                default:
                    lines = []
                }
                stream.append(Self.commandResultBlock(number: commandNumber, lines: lines))
                commandNumber += 1
            }
            deliverRechunked(stream, to: fixture.connection)
        }

        #expect(seeds.count == 2)
        #expect(seeds.allSatisfy { $0.kind == .visibleRepaint })
        var expectedAlternate = RemoteTmuxControlConnection.altScreenEnterSequence
        expectedAlternate.append(Data("\u{1b}[H\u{1b}[2JALT_SCREEN".utf8))
        #expect(seeds.first?.snapshot == expectedAlternate)

        var expectedPrimary = RemoteTmuxControlConnection.altScreenExitSequence
        expectedPrimary.append(Data("\u{1b}[H\u{1b}[2JPRIMARY_SCREEN".utf8))
        #expect(seeds.last?.snapshot == expectedPrimary)
    }

    /// A visible-screen repair after a verified pane-height grow must not turn
    /// rows already represented in primary-screen history into a second copy.
    /// This drives the real Ghostty manual-I/O parser because observer-byte
    /// equality alone cannot expose corruption retained outside the viewport.
    @Test(.timeLimit(.minutes(1)))
    func visibleRepaintAfterGridGrowthPreservesPrimaryScreenHistory() async throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        let initialLayout = RemoteTmuxLayoutNode(
            width: 80, height: 26, x: 0, y: 0, content: .pane(7)
        )
        let initialWindow = RemoteTmuxWindow(
            id: 1,
            name: "main",
            width: 80,
            height: 26,
            layout: initialLayout
        )
        fixture.connection.windowsByID[1] = initialWindow
        fixture.connection.windowOrder = [1]
        fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let sessionMirror = RemoteTmuxSessionMirror(
            host: fixture.connection.host,
            sessionName: "work",
            connection: fixture.connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }
        let panelID = try #require(sessionMirror.panelIdByPane[7])
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let terminal = try hostedTerminal(panel.surface)
        defer { terminal.window.orderOut(nil) }
        await waitForLiveSurface(terminal.surface)
        try #require(terminal.surface.hasLiveSurface)

        terminal.surface.setAssignedGrid(columns: 80, rows: 26)
        await waitForAppliedTerminalGrid(terminal.surface, columns: 80, rows: 26)

        let authoritativeRows = (1...80).map { String(format: "HISTORY_ROW_%03d", $0) }
        finishPendingCommands(
            on: fixture.connection,
            captureRows: authoritativeRows,
            paneHeight: 26,
            startingAt: 20
        )
        await waitForTerminalText(terminal.surface) { text in
            authoritativeRows.allSatisfy {
                text.components(separatedBy: $0).count - 1 == 1
            }
        }
        terminal.surface.setManualIONoReflow(false)

        let grownLayout = RemoteTmuxLayoutNode(
            width: 80, height: 50, x: 0, y: 0, content: .pane(7)
        )
        let grownWindow = RemoteTmuxWindow(
            id: 1,
            name: "main",
            width: 80,
            height: 50,
            layout: grownLayout
        )
        fixture.connection.windowsByID[1] = grownWindow
        fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])
        fixture.connection.observers.notifyTopologyChanged()
        fixture.connection.repaintPanesThatGrew(from: initialWindow, to: grownWindow)

        finishPendingCommands(
            on: fixture.connection,
            captureRows: Array(authoritativeRows.suffix(50)),
            paneHeight: 50,
            startingAt: 50
        )

        terminal.surface.setAssignedGrid(columns: 80, rows: 50)
        await waitForAppliedTerminalGrid(terminal.surface, columns: 80, rows: 50)
        await waitForTerminalText(terminal.surface) { text in
            text.contains(authoritativeRows[79])
        }

        let rendered = try readFullTerminalText(terminal.surface)
        for row in authoritativeRows {
            #expect(
                rendered.components(separatedBy: row).count - 1 == 1,
                "verified growth must preserve exactly one copy of \(row)"
            )
        }
    }

    /// A reconnect capture replaces the entire primary screen and scrollback.
    /// Once that authoritative seed lands, reconnect readiness must not run the
    /// legacy rows-minus-one attach kick: shrinking 26 -> 25 moves the first
    /// visible row into local history, and the growth repaint then paints that
    /// same row again at the viewport boundary.
    @Test(.timeLimit(.minutes(1)))
    func reconnectReseedReplacesPrimaryHistoryAtVisibleBoundary() async throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        let initialLayout = RemoteTmuxLayoutNode(
            width: 80, height: 26, x: 0, y: 0, content: .pane(7)
        )
        let initialWindow = RemoteTmuxWindow(
            id: 1,
            name: "main",
            width: 80,
            height: 26,
            layout: initialLayout
        )
        fixture.connection.windowsByID[1] = initialWindow
        fixture.connection.windowOrder = [1]
        fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let sessionMirror = RemoteTmuxSessionMirror(
            host: fixture.connection.host,
            sessionName: "work",
            connection: fixture.connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }
        let panelID = try #require(sessionMirror.panelIdByPane[7])
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let terminal = try hostedTerminal(panel.surface)
        defer { terminal.window.orderOut(nil) }
        await waitForLiveSurface(terminal.surface)
        try #require(terminal.surface.hasLiveSurface)

        terminal.surface.setAssignedGrid(columns: 80, rows: 26)
        await waitForAppliedTerminalGrid(terminal.surface, columns: 80, rows: 26)

        let markers = (1...66).map { String(format: "RECONNECT_ROW_%03d", $0) }
        let authoritativeRows = markers + [
            "P10K:DIR:/opt/cmux/fixture/tailscale VCS:issue-7990-a884",
            "PROMPT:❯",
            "",
            "",
            "",
        ]
        finishPendingCommands(
            on: fixture.connection,
            captureRows: authoritativeRows,
            paneHeight: 26,
            startingAt: 20
        )
        await waitForTerminalText(terminal.surface) { text in
            markers.allSatisfy { text.components(separatedBy: $0).count - 1 == 1 }
        }

        fixture.connection.pendingAttachRedrawKick = false
        fixture.connection.lastClientSize = (columns: 80, rows: 26)
        fixture.connection.lastWindowSizes[1] = (80, 26)
        fixture.connection.lastSizeRequestWindowId = 1
        _ = fixture.pipe.fileHandleForReading.availableData

        fixture.connection.beginReconnecting()
        let reconnectPipe = Pipe()
        let reconnectWriter = RemoteTmuxControlPipeWriter(
            handle: reconnectPipe.fileHandleForWriting,
            label: "remote-tmux-pane-reconnect-kick-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        fixture.connection.installStdinWriterForTesting(reconnectWriter)
        defer {
            reconnectWriter.close()
            try? reconnectPipe.fileHandleForReading.close()
        }
        fixture.connection.handleMessageForTesting(.enter)
        fixture.connection.reseedAfterReconnect()
        finishPendingCommands(
            on: fixture.connection,
            captureRows: authoritativeRows,
            paneHeight: 26,
            startingAt: 50
        )
        await waitForTerminalText(terminal.surface) { text in
            text.contains(markers[65])
        }
        await Task.yield()

        let reconnectCommands = String(
            decoding: reconnectPipe.fileHandleForReading.availableData,
            as: UTF8.self
        )
        let emittedPostSeedShrink = reconnectCommands.contains(
            "refresh-client -C '@1:80x25'"
        )
        #expect(
            !emittedPostSeedShrink,
            "an authoritative reconnect seed must not be followed by a 26 -> 25 attach kick"
        )

        if emittedPostSeedShrink {
            terminal.surface.setManualIONoReflow(false)
            let shrunkenLayout = RemoteTmuxLayoutNode(
                width: 80, height: 25, x: 0, y: 0, content: .pane(7)
            )
            let shrunkenWindow = RemoteTmuxWindow(
                id: 1,
                name: "main",
                width: 80,
                height: 25,
                layout: shrunkenLayout
            )
            fixture.connection.windowsByID[1] = shrunkenWindow
            fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])
            fixture.connection.observers.notifyTopologyChanged()
            terminal.surface.setAssignedGrid(columns: 80, rows: 25)
            await waitForAppliedTerminalGrid(terminal.surface, columns: 80, rows: 25)

            let restoredWindow = RemoteTmuxWindow(
                id: 1,
                name: "main",
                width: 80,
                height: 26,
                layout: initialLayout
            )
            fixture.connection.windowsByID[1] = restoredWindow
            fixture.connection.recordPublishedPaneOwnership(windowId: 1, paneIds: [7])
            fixture.connection.observers.notifyTopologyChanged()
            fixture.connection.repaintPanesThatGrew(
                from: shrunkenWindow,
                to: restoredWindow
            )
            terminal.surface.setAssignedGrid(columns: 80, rows: 26)
            await waitForAppliedTerminalGrid(terminal.surface, columns: 80, rows: 26)
            finishPendingCommands(
                on: fixture.connection,
                captureRows: Array(authoritativeRows.suffix(26)),
                paneHeight: 26,
                startingAt: 80
            )
            await waitForTerminalText(terminal.surface) { text in
                text.contains(markers[65])
            }
        }

        let rendered = try readFullTerminalText(terminal.surface)
        for marker in markers {
            #expect(
                rendered.components(separatedBy: marker).count - 1 == 1,
                "reconnect reseed must preserve exactly one copy of \(marker)"
            )
        }
    }

    private static func seedRaceStream(
        preCaptureOutput: String,
        capturedRows: [String],
        postCaptureOutput: String,
        paneState: String,
        paneID: Int = 7
    ) -> Data {
        let text = "%output %\(paneID) \(preCaptureOutput)\r\n"
            + "%begin 1700000000 10 0\r\n"
            + "%end 1700000000 10 0\r\n"
            + "%begin 1700000000 11 0\r\n"
            + "0\r\n"
            + "%end 1700000000 11 0\r\n"
            + "%begin 1700000000 12 0\r\n"
            + capturedRows.joined(separator: "\r\n") + "\r\n"
            + "%end 1700000000 12 0\r\n"
            + "%output %\(paneID) \(postCaptureOutput)\r\n"
            + "%begin 1700000000 13 0\r\n"
            + paneState + "\r\n"
            + "%end 1700000000 13 0\r\n"
            + "%begin 1700000000 14 0\r\n"
            + "%end 1700000000 14 0\r\n"
        return Data(text.utf8)
    }

    private static func paneStateLine(
        cursorX: Int,
        cursorY: Int,
        paneHeight: Int = 24
    ) -> String {
        "cursor_x=\(cursorX),cursor_y=\(cursorY),"
            + "scroll_region_upper=0,scroll_region_lower=\(paneHeight - 1),"
            + "cursor_flag=1,insert_flag=0,keypad_cursor_flag=0,keypad_flag=0,"
            + "wrap_flag=1,origin_flag=0,pane_height=\(paneHeight),"
            + "mouse_all_flag=0,mouse_button_flag=0,mouse_standard_flag=0,"
            + "mouse_sgr_flag=0,mouse_utf8_flag=0"
    }

    private static func commandResultBlock(number: Int, lines: [String]) -> Data {
        let body = lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
        return Data(
            ("%begin 1700000000 \(number) 0\r\n"
                + body
                + "%end 1700000000 \(number) 0\r\n").utf8
        )
    }

    private static func occurrences(of needle: String, in data: Data) -> Int {
        String(decoding: data, as: UTF8.self).components(separatedBy: needle).count - 1
    }

    /// Simulates a lumpy userspace SSH transport without clocks: tmux protocol
    /// bytes remain ordered, but lines and escape payloads cross read boundaries.
    private func deliverRechunked(_ bytes: Data, to connection: RemoteTmuxControlConnection) {
        var parser = RemoteTmuxControlStreamParser()
        let chunkSizes = [1, 13, 2, 31, 5, 3, 47, 8]
        var offset = bytes.startIndex
        var chunkIndex = 0
        while offset < bytes.endIndex {
            let count = min(
                chunkSizes[chunkIndex % chunkSizes.count],
                bytes.distance(from: offset, to: bytes.endIndex)
            )
            let end = bytes.index(offset, offsetBy: count)
            for message in parser.feed(Data(bytes[offset..<end])) {
                connection.handleMessageForTesting(message)
            }
            offset = end
            chunkIndex += 1
        }
    }

    private func attachedConnection(
        pendingPaneSeedByteLimit: Int = RemoteTmuxControlConnection.maximumPendingPaneSeedBytes
    ) -> Fixture {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "seed-transport.test"),
            sessionName: "work",
            pendingPaneSeedByteLimit: pendingPaneSeedByteLimit
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-pane-seed-transport-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 1, lines: [], isError: false)
        )
        _ = pipe.fileHandleForReading.availableData
        return Fixture(connection: connection, writer: writer, pipe: pipe)
    }

    private func finishPendingCommands(
        on connection: RemoteTmuxControlConnection,
        captureRows: [String],
        paneHeight: Int,
        startingAt firstCommandNumber: Int
    ) {
        var commandNumber = firstCommandNumber
        while let kind = connection.pendingCommandKindsForTesting.first {
            let lines: [String]
            switch kind {
            case .paneReflow:
                lines = ["0|zsh"]
            case .paneAltScreen:
                lines = ["0"]
            case .capturePane:
                lines = captureRows
            case .paneState:
                lines = [
                    Self.paneStateLine(
                        cursorX: 0,
                        cursorY: paneHeight - 1,
                        paneHeight: paneHeight
                    )
                ]
            case .panePath:
                lines = ["/tmp"]
            default:
                lines = []
            }
            connection.handleMessageForTesting(
                .commandResult(commandNumber: commandNumber, lines: lines, isError: false)
            )
            commandNumber += 1
        }
    }

    private func hostedTerminal(_ surface: TerminalSurface) throws -> HostedTerminal {
        _ = NSApplication.shared
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        return HostedTerminal(surface: surface, window: window)
    }

    private func waitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                continuation.yield()
                continuation.finish()
            }
        }
        for await _ in readiness { break }
        surface.onRuntimeReady = nil
    }

    private func waitForAppliedTerminalGrid(
        _ surface: TerminalSurface,
        columns: Int,
        rows: Int
    ) async {
        await waitForGhosttyState(surface) {
            guard let frame = surface.mobileRenderGridFrame(
                stateSeq: 0,
                scrollbackLines: 0,
                includeTheme: false
            )?.frame else { return false }
            return frame.columns == columns && frame.rows == rows
        }
    }

    private func waitForAppliedTerminalGridUsingTicks(
        _ surface: TerminalSurface,
        columns: Int,
        rows: Int
    ) async {
        let gridIsApplied = {
            surface.mobileRenderGridFrame(
                stateSeq: 0,
                scrollbackLines: 0,
                includeTheme: false
            )?.frame
        }
        if let frame = gridIsApplied(), frame.columns == columns, frame.rows == rows {
            return
        }

        let releaseTicks = GhosttyApp.retainTickNotifications()
        defer { releaseTicks() }
        let (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let token = NotificationCenter.default.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { _ in
            continuation.yield()
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            continuation.finish()
        }

        GhosttyApp.shared.scheduleTick()
        for await _ in events {
            guard let frame = gridIsApplied() else { continue }
            if frame.columns == columns, frame.rows == rows { return }
        }
    }

    private func waitForTerminalText(
        _ surface: TerminalSurface,
        condition: @escaping @MainActor (String) -> Bool
    ) async {
        await waitForGhosttyState(surface) {
            guard let text = try? readFullTerminalText(surface) else { return false }
            return condition(text)
        }
    }

    private func waitForGhosttyState(
        _ surface: TerminalSurface,
        condition: @escaping @MainActor () -> Bool
    ) async {
        if condition() { return }

        let releaseTicks = GhosttyApp.retainTickNotifications()
        let releaseFrames = GhosttyNSView.retainRenderedFrameNotifications()
        defer {
            releaseFrames()
            releaseTicks()
        }
        let (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: .ghosttyDidTick, object: nil, queue: .main) { _ in
                continuation.yield()
            },
            center.addObserver(forName: .ghosttyDidRenderFrame, object: nil, queue: .main) { _ in
                continuation.yield()
            },
            center.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: surface,
                queue: .main
            ) { _ in
                continuation.yield()
            },
        ]
        defer {
            for token in tokens { center.removeObserver(token) }
            continuation.finish()
        }

        if condition() { return }
        GhosttyApp.shared.scheduleTick()
        for await _ in events where !condition() {}
    }

    private func readTerminalText(
        _ surface: TerminalSurface,
        pointTag: ghostty_point_tag_e
    ) throws -> String {
        let runtimeSurface = try #require(surface.surface)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: pointTag,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: pointTag,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(runtimeSurface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(runtimeSurface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: Data(bytes: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    private func readFullTerminalText(_ surface: TerminalSurface) throws -> String {
        let snapshot = TerminalController.TerminalTextRawSnapshot(
            viewport: nil,
            screen: try readTerminalText(surface, pointTag: GHOSTTY_POINT_SCREEN),
            history: try readTerminalText(surface, pointTag: GHOSTTY_POINT_SURFACE),
            active: try readTerminalText(surface, pointTag: GHOSTTY_POINT_ACTIVE)
        )
        switch TerminalController.terminalTextPayload(
            from: snapshot,
            includeScrollback: true,
            lineLimit: nil
        ) {
        case .success(let payload):
            return payload.text
        case .failure(let error):
            Issue.record("failed to read terminal history: \(error.message)")
            return ""
        }
    }

    private struct HostedTerminal {
        let surface: TerminalSurface
        let window: NSWindow
    }

    private struct Fixture {
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe

        @MainActor func close() {
            connection.stop()
            writer.close()
            try? pipe.fileHandleForReading.close()
        }
    }
}
