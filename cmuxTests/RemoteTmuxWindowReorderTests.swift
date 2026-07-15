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
        reply(connection, lines: ["%0 0 0 80 24 1 off :0 \"ejc3-mac\""])
    }

    private func windowLines(_ order: [Int]) -> [String] {
        order.map {
            "@\($0) f92f,80x24,0,0,\($0 * 10) f92f,80x24,0,0,\($0 * 10) [] window-\($0)"
        }
    }

    private func windowOrderLines(_ order: [Int]) -> [String] { order.map { "@\($0)" } }

    private func publishWindows(_ connection: RemoteTmuxControlConnection, order: [Int]) {
        reply(connection, lines: windowLines(order))
        drainPendingPaneRects(connection)
    }

    private func drainPendingPaneRects(_ connection: RemoteTmuxControlConnection) {
        while let kind = connection.pendingCommandKindsForTesting.first {
            guard case let .paneRects(windowId, _) = kind else { return }
            reply(connection, lines: ["%\(windowId * 10) 0 0 80 24 1 off :zsh"])
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
        var firstVerification: RemoteTmuxMutationOutcome?

        #expect(connection.sendWindowReorder(
            ["swap-window -d -s @1 -t @2"],
            verification: { firstVerification = $0 }
        ))
        connection.applyWindowReorder([2, 1, 3])
        reply(connection, lines: [])
        #expect(!connection.sendWindowReorder(["swap-window -d -s @1 -t @3"]))
        #expect(connection.pendingCommandKindsForTesting == [.listWindowOrder(reorderGeneration: 1)])

        reply(connection, lines: windowOrderLines([2, 1, 3]))
        #expect(firstVerification == .applied)
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
        var verification: RemoteTmuxMutationOutcome?

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
        #expect(verification == .applied)
        #expect(connection.windowOrder == [2, 1, 3])
    }

    @Test func overlappingWindowClosesReleaseOnlyTheirOwnRetainedPaneIDs() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2, 3])

        connection.handleMessageForTesting(.windowClose(windowId: 1))
        connection.handleMessageForTesting(.windowClose(windowId: 2))
        #expect(connection.pendingCommandKindsForTesting == [
            .listWindows(reorderGeneration: 0, retainedPaneIDs: [10]),
        ])

        // Burst closes share one in-flight snapshot. Its completion releases only
        // pane 10 and queues one follow-up containing the later close's pane 20.
        reply(connection, lines: windowLines([2, 3]))
        #expect(connection.paneIDsRetainedUntilWindowList == [20])
        // The topology snapshot restages authoritative pane rectangles before
        // the coalesced follow-up list reply can occupy the FIFO head.
        drainPendingPaneRects(connection)
        #expect(connection.pendingCommandKindsForTesting == [
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
        var verification: RemoteTmuxMutationOutcome?

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
        #expect(verification == .applied)
        #expect(connection.windowOrder == [2, 1, 3, 4])
        #expect(connection.sendWindowReorder(["swap-window -d -s @2 -t @1"]))
    }

    @Test func recoveryEscalationFailsVerificationWhenOrderDidNotLand() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2, 3])
        var verification: RemoteTmuxMutationOutcome?

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
        #expect(verification == .rejected)
        #expect(connection.windowOrder == [1, 2, 3, 4])
    }

    @Test func matchingOrderCompletesVerificationSuccessfully() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2])
        var verification: RemoteTmuxMutationOutcome?

        #expect(connection.sendWindowReorder(
            ["swap-window -d -s @1 -t @2"],
            verification: { verification = $0 }
        ))
        connection.applyWindowReorder([2, 1])
        reply(connection, lines: [])
        #expect(verification == nil)

        reply(connection, lines: windowOrderLines([2, 1]))
        #expect(verification == .applied)
    }

    @Test func orderRefreshSendFailureFencesUntilAuthoritativeRecovery() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishWindows(connection, order: [1, 2])
        var verification: RemoteTmuxMutationOutcome?

        #expect(connection.sendWindowReorder(
            ["swap-window -d -s @1 -t @2"],
            verification: { verification = $0 }
        ))
        connection.applyWindowReorder([2, 1])

        // Simulate losing the command writer after tmux accepted the swap but
        // before cmux can send the cheap order-only verification request.
        connection.stdinWriter = nil
        reply(connection, lines: [])

        #expect(verification == .unknown)
        #expect(connection.windowOrder == [2, 1])
        #expect(connection.windowReorderRecoveryGeneration == 1)
        #expect(!connection.sendWindowReorder(["swap-window -d -s @2 -t @1"]))

        // Restoring transport and fetching full topology must replace the
        // optimistic order before another mutation can begin.
        connection.installStdinWriterForTesting(writer)
        connection.requestWindows()
        #expect(connection.pendingCommandKindsForTesting == [
            .listWindows(reorderGeneration: 1, retainedPaneIDs: [])
        ])
        reply(connection, lines: windowLines([1, 2]))

        #expect(connection.windowOrder == [1, 2])
        #expect(connection.windowReorderRecoveryGeneration == nil)
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

        #expect(events == ["verification:rejected", "topology"])
        #expect(connection.windowOrder == [1, 2])
    }
}
