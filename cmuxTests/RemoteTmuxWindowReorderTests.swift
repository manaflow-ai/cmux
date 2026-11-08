import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct RemoteTmuxWindowReorderTests {
    /// Returns an attached control connection whose attach reply has drained.
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
            label: "remote-tmux-window-reorder-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        reply(connection, lines: [])
        return (connection, writer, pipe)
    }

    private func reply(
        _ connection: RemoteTmuxControlConnection,
        lines: [String],
        isError: Bool = false
    ) {
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: lines, isError: isError)
        )
    }

    /// Publishes one window and drains its pane-rect command, leaving an empty FIFO.
    private func publishSinglePaneWindow(_ connection: RemoteTmuxControlConnection) {
        reply(connection, lines: ["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] main"])
        drainPendingSetupCommands(connection)
    }

    /// Answers every follow-up command a window-list publish enqueues so the FIFO is
    /// empty before a test starts its reorder scenario. Since #7315 a window-list
    /// reply enqueues not just a per-window `paneRects` fetch but also a follow-up
    /// (`.other`, e.g. a size/subscription push); an undrained command left at the
    /// FIFO head consumes the next positional reply, mis-correlating a reorder
    /// batch's result and silently skipping its recovery/reconnect.
    private func drainPendingSetupCommands(_ connection: RemoteTmuxControlConnection) {
        var guardCount = 0
        // Consume only the incidental follow-ups. A blind reply to whatever sits at the
        // head would swallow a `listWindows`/`windowReorder` and mis-correlate its
        // positional reply, so stop at the first correlated command.
        loop: while guardCount < 16, let kind = connection.pendingCommandKindsForTesting.first {
            guardCount += 1
            switch kind {
            case .paneRects:
                reply(connection, lines: ["%0 0 0 80 24 1 off :0 \"ejc3-mac\""])
            case .other:
                reply(connection, lines: [])
            default:
                break loop
            }
        }
    }

    private func windowLines(_ order: [Int]) -> [String] {
        order.map {
            "@\($0) f92f,80x24,0,0,\($0 * 10) f92f,80x24,0,0,\($0 * 10) [] window-\($0)"
        }
    }

    private func windowOrderLines(_ order: [Int]) -> [String] { order.map { "@\($0)" } }

    /// Answers the incidental setup commands a close / re-publish enqueues — the
    /// border-status unsubscribe (`.other`) and the per-window `paneRects` refetch
    /// (a re-published window re-stages its rects) — stopping at the next correlated
    /// command (`listWindows`/`listWindowOrder`/`windowReorder`). Left at the FIFO
    /// head, either would swallow the next positional reply meant for that command.
    private func drainLeadingOther(_ connection: RemoteTmuxControlConnection) {
        var guardCount = 0
        loop: while guardCount < 16, let kind = connection.pendingCommandKindsForTesting.first {
            guardCount += 1
            switch kind {
            case .other:
                reply(connection, lines: [])
            case let .paneRects(windowId, _):
                // Reply with the pane id belonging to the requested window (the
                // `windowId * 10` convention `publishWindows` stages), so a
                // re-published @2/@3's rects publish correctly — not always `%0`.
                reply(connection, lines: ["%\(windowId * 10) 0 0 80 24 1 off :zsh"])
            default:
                break loop
            }
        }
    }

    private func isIncidentalFollowUp(_ kind: RemoteTmuxControlCommandKind) -> Bool {
        switch kind {
        case .other, .paneRects: return true
        default: return false
        }
    }

    /// The pending command kinds with only the TRAILING incidental follow-ups dropped
    /// — the border-status unsubscribe (`.other`) and the per-window `paneRects`
    /// refetch a re-published window re-stages, which #7315 legitimately appends after
    /// a `listWindows`. Incidentals are trimmed only from the tail, so one that lands
    /// BETWEEN meaningful commands (an ordering anomaly indicating a broken
    /// command-batch boundary) survives and fails the equality assertion instead of
    /// being silently elided by a blanket filter.
    private func reorderPending(_ connection: RemoteTmuxControlConnection) -> [RemoteTmuxControlCommandKind] {
        var kinds = connection.pendingCommandKindsForTesting
        while let last = kinds.last, isIncidentalFollowUp(last) { kinds.removeLast() }
        return kinds
    }

    private func publishWindows(_ connection: RemoteTmuxControlConnection, order: [Int]) {
        reply(connection, lines: windowLines(order))
        // Drain every follow-up (per-window paneRects AND the trailing `.other`
        // push #7315 added) so the FIFO is empty before the reorder scenario; a
        // leftover would mis-correlate later positional replies. See
        // ``drainPendingSetupCommands``.
        var guardCount = 0
        loop: while guardCount < 16, let kind = connection.pendingCommandKindsForTesting.first {
            guardCount += 1
            switch kind {
            case let .paneRects(windowId, _):
                reply(connection, lines: ["%\(windowId * 10) 0 0 80 24 1 off :zsh"])
            case .other:
                reply(connection, lines: [])
            default:
                // Never blind-reply to a correlated command (see drainPendingSetupCommands).
                break loop
            }
        }
    }

    @Test func successfulBatchQueuesAnAuthoritativeWindowRefresh() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        #expect(connection.sendWindowReorder([
            "swap-window -d -s @1 -t @2",
            "swap-window -d -s @2 -t @3",
        ]))
        reply(connection, lines: [])
        #expect(connection.pendingCommandKindsForTesting == [.windowReorder(isLast: true)])
        reply(connection, lines: [])

        #expect(connection.pendingCommandKindsForTesting == [.listWindowOrder(reorderGeneration: 1)])
    }

    @Test func matchingGenerationRefreshReplacesOptimisticWindowOrder() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2, 3])

        #expect(connection.sendWindowReorder(["swap-window -d -s @1 -t @2"]))
        connection.applyWindowReorder([2, 1, 3])
        reply(connection, lines: [])
        reply(connection, lines: windowOrderLines([3, 1, 2]))

        #expect(connection.windowOrder == [3, 1, 2])
    }

    @Test func pendingVerificationRejectsAnOverlappingReorder() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2, 3])
        var firstVerification: Bool?

        #expect(connection.sendWindowReorder(
            ["swap-window -d -s @1 -t @2"],
            verification: { firstVerification = $0 }
        ))
        connection.applyWindowReorder([2, 1, 3])
        reply(connection, lines: [])
        #expect(!connection.sendWindowReorder(["swap-window -d -s @1 -t @3"]))
        #expect(connection.pendingCommandKindsForTesting == [.listWindowOrder(reorderGeneration: 1)])

        reply(connection, lines: windowOrderLines([2, 1, 3]))
        #expect(firstVerification == true)
        #expect(connection.sendWindowReorder(["swap-window -d -s @1 -t @3"]))
        connection.applyWindowReorder([2, 3, 1])
        reply(connection, lines: [])
        #expect(connection.pendingCommandKindsForTesting == [.listWindowOrder(reorderGeneration: 2)])
        reply(connection, lines: windowOrderLines([2, 3, 1]))
        #expect(connection.windowOrder == [2, 3, 1])
    }

    @Test func orderRefreshMembershipChangeFallsBackToFullTopologyRefresh() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        #expect(connection.sendWindowReorder(["swap-window -d -s @1 -t @2"]))
        reply(connection, lines: [])
        #expect(connection.pendingCommandKindsForTesting == [.listWindowOrder(reorderGeneration: 1)])
        reply(connection, lines: windowOrderLines([1, 2]))

        #expect(connection.pendingCommandKindsForTesting == [
            .listWindows(reorderGeneration: 1, retainedPaneIDs: [])
        ])
        #expect(!connection.sendWindowReorder(["swap-window -d -s @1 -t @2"]))
    }

    @Test func malformedOrderRefreshFallsBackToBlockingFullRecovery() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        #expect(connection.sendWindowReorder(["swap-window -d -s @1 -t @2"]))
        reply(connection, lines: [])
        reply(connection, lines: ["garbled order"])

        #expect(connection.pendingCommandKindsForTesting == [
            .listWindows(reorderGeneration: 1, retainedPaneIDs: [])
        ])
        #expect(!connection.sendWindowReorder(["swap-window -d -s @1 -t @2"]))
    }

    @Test func failedBatchRejectsAnotherReorderUntilAuthoritativeRecovery() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)
        connection.windowOrder = [1, 2]

        #expect(connection.sendWindowReorder(["swap-window -d -s @1 -t @2"]))
        connection.applyWindowReorder([2, 1])
        reply(connection, lines: ["can't find window: @2"], isError: true)
        #expect(connection.pendingCommandKindsForTesting == [
            .listWindows(reorderGeneration: 1, retainedPaneIDs: [])
        ])

        #expect(!connection.sendWindowReorder(["swap-window -d -s @2 -t @1"]))
        #expect(connection.pendingCommandKindsForTesting == [
            .listWindows(reorderGeneration: 1, retainedPaneIDs: [])
        ])
        #expect(connection.windowOrder == [2, 1])
        reply(connection, lines: windowLines([2, 3, 1]))

        #expect(connection.windowOrder == [2, 3, 1])
        #expect(connection.sendWindowReorder(["swap-window -d -s @2 -t @1"]))
    }

    @Test(arguments: [true, false])
    func unusableRecoveryForcesReconnect(isError: Bool) {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)
        #expect(connection.sendWindowReorder(["swap-window -d -s @1 -t @2"]))
        reply(connection, lines: ["can't find window: @2"], isError: true)
        #expect(connection.pendingCommandKindsForTesting == [
            .listWindows(reorderGeneration: 1, retainedPaneIDs: [])
        ])

        reply(
            connection,
            lines: [isError ? "recovery rejected" : "garbled topology"],
            isError: isError
        )

        #expect(connection.connectionState == .reconnecting)
    }

    @Test func topologyRefreshDuringPendingVerificationKeepsOptimisticOrder() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2, 3])
        var verification: Bool?

        #expect(connection.sendWindowReorder(
            ["swap-window -d -s @1 -t @2"],
            verification: { verification = $0 }
        ))
        connection.applyWindowReorder([2, 1, 3])
        // An incidental topology refetch (e.g. triggered by %window-add) is
        // tagged with the current generation while the batch is unverified.
        connection.requestWindows()
        reply(connection, lines: [])
        reply(connection, lines: windowLines([1, 2, 3]))

        // The refetch must not replace the optimistic order mid-verification;
        // the pending `listWindowOrder` remains the authority for this batch.
        #expect(connection.windowOrder == [2, 1, 3])
        #expect(verification == nil)
        reply(connection, lines: windowOrderLines([2, 1, 3]))
        #expect(verification == true)
        #expect(connection.windowOrder == [2, 1, 3])
    }

    @Test func overlappingWindowClosesReleaseOnlyTheirOwnRetainedPaneIDs() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2, 3])

        connection.handleMessageForTesting(.windowClose(windowId: 1))
        connection.handleMessageForTesting(.windowClose(windowId: 2))
        // Each close also enqueues a border-status unsubscribe (.other); drain the
        // leading one so the window-list replies below correlate to the retention
        // list-windows, and compare with the unsubscribes filtered out.
        drainLeadingOther(connection)
        #expect(reorderPending(connection) == [
            .listWindows(reorderGeneration: 0, retainedPaneIDs: [10]),
        ])

        // Burst closes share one in-flight snapshot. Its completion releases only
        // pane 10 and queues one follow-up containing the later close's pane 20.
        reply(connection, lines: windowLines([2, 3]))
        #expect(connection.paneIDsRetainedUntilWindowList == [20])
        // Re-publishing @2/@3 re-stages their paneRects ahead of the follow-up
        // list-windows; drain them so the next reply correlates to the list-windows.
        drainLeadingOther(connection)
        #expect(reorderPending(connection) == [
            .listWindows(reorderGeneration: 0, retainedPaneIDs: [20]),
        ])

        reply(connection, lines: windowLines([3]))
        #expect(connection.paneIDsRetainedUntilWindowList.isEmpty)
    }

    @Test(arguments: [true, false])
    func unusableCloseRefreshReconnectsWithoutReleasingIdentity(isError: Bool) {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2])

        connection.handleMessageForTesting(.windowClose(windowId: 1))
        // The close enqueues a border-status unsubscribe (.other) ahead of its
        // list-windows refresh; drain it so the unusable reply below lands on the
        // refresh (whose failure forces the reconnect), not the unsubscribe.
        drainLeadingOther(connection)
        reply(
            connection,
            lines: [isError ? "refresh rejected" : "garbled topology"],
            isError: isError
        )

        #expect(connection.connectionState == .reconnecting)
        #expect(connection.paneIDsRetainedUntilWindowList == [10])
    }

    @Test func recoveryEscalationVerifiesAgainstAuthoritativeOrder() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2, 3])
        var verification: Bool?

        #expect(connection.sendWindowReorder(
            ["swap-window -d -s @1 -t @2"],
            verification: { verification = $0 }
        ))
        connection.applyWindowReorder([2, 1, 3])
        reply(connection, lines: [])
        // A window added mid-batch makes the cheap order check inconclusive;
        // the batch must stay pending instead of being failed outright.
        reply(connection, lines: windowOrderLines([2, 1, 3, 4]))
        #expect(verification == nil)

        // Recovery shows tmux holding the desired relative order (plus the
        // new window), so the batch verifies as applied — pin state survives.
        reply(connection, lines: windowLines([2, 1, 3, 4]))
        #expect(verification == true)
        #expect(connection.windowOrder == [2, 1, 3, 4])
        #expect(connection.sendWindowReorder(["swap-window -d -s @2 -t @1"]))
    }

    @Test func recoveryEscalationFailsVerificationWhenOrderDidNotLand() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2, 3])
        var verification: Bool?

        #expect(connection.sendWindowReorder(
            ["swap-window -d -s @1 -t @2"],
            verification: { verification = $0 }
        ))
        connection.applyWindowReorder([2, 1, 3])
        reply(connection, lines: [])
        reply(connection, lines: windowOrderLines([2, 1, 3, 4]))
        #expect(verification == nil)

        // Recovery shows the batch's windows NOT in the desired order.
        reply(connection, lines: windowLines([1, 2, 3, 4]))
        #expect(verification == false)
        #expect(connection.windowOrder == [1, 2, 3, 4])
    }

    @Test func matchingOrderCompletesVerificationSuccessfully() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2])
        var verification: Bool?

        #expect(connection.sendWindowReorder(
            ["swap-window -d -s @1 -t @2"],
            verification: { verification = $0 }
        ))
        connection.applyWindowReorder([2, 1])
        reply(connection, lines: [])
        #expect(verification == nil)

        reply(connection, lines: windowOrderLines([2, 1]))
        #expect(verification == true)
    }

    @Test func mismatchedOrderFailsVerificationBeforeTopologyPublication() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2])
        var events: [String] = []
        let observer = connection.addObserver(onTopologyChanged: {
            events.append("topology")
        })
        defer { connection.removeObserver(observer) }

        #expect(connection.sendWindowReorder(
            ["swap-window -d -s @1 -t @2"],
            verification: { events.append("verification:\($0)") }
        ))
        connection.applyWindowReorder([2, 1])
        reply(connection, lines: [])
        reply(connection, lines: windowOrderLines([1, 2]))

        #expect(events == ["verification:false", "topology"])
        #expect(connection.windowOrder == [1, 2])
    }
}
