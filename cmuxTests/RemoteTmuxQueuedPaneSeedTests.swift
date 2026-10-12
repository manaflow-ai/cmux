import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A host with many windows mounts every pane of every mirrored workspace in one
/// main-actor turn. Each pane seed is about a dozen commands and a capture of up to
/// 5,000 lines of history, so seeding them all at once queues more stdin than the
/// control writer allows, and the stream reconnects only to do it again.
@MainActor
@Suite struct RemoteTmuxQueuedPaneSeedTests {
    /// The control writer's real stdin budget.
    private static let stdinBudget = 256 * 1024

    @Test func seedingEveryPaneAtOnceOverflowsTheControlWriter() {
        let fixture = Self.attachedConnection()
        defer { fixture.close() }

        for paneId in 1...1_500 {
            fixture.connection.seedPane(paneId: paneId, clearScrollback: true)
        }

        #expect(fixture.connection.connectionState != .connected)
        #expect(fixture.connection.snapshot().recentEvents.contains("stdin-write-backpressure"))
    }

    @Test func mountingManyPanesStartsOnlyAFewSeedsAtOnce() {
        let fixture = Self.attachedConnection()
        defer { fixture.close() }

        for paneId in 1...1_500 {
            fixture.connection.queuePaneSeed(paneId: paneId)
        }

        let limit = RemoteTmuxControlConnection.maximumConcurrentQueuedPaneSeeds
        #expect(fixture.connection.connectionState == .connected)
        #expect(fixture.connection.pendingPaneSeeds.count == limit)
        #expect(fixture.connection.queuedPaneSeedPaneIDs.count == 1_500 - limit)
        #expect(Set(fixture.connection.pendingPaneSeeds.keys) == Set(1...limit))
    }

    @Test func queueingAPaneTwiceSeedsItOnce() {
        let fixture = Self.attachedConnection()
        defer { fixture.close() }

        let limit = RemoteTmuxControlConnection.maximumConcurrentQueuedPaneSeeds
        for paneId in 1...(limit + 2) {
            fixture.connection.queuePaneSeed(paneId: paneId)
        }
        fixture.connection.queuePaneSeed(paneId: limit + 1)
        fixture.connection.queuePaneSeed(paneId: 1)

        #expect(fixture.connection.queuedPaneSeedPaneIDs == [limit + 1, limit + 2])
        #expect(fixture.connection.pendingPaneSeeds[1]?.count == 1)
    }

    @Test func finishingASeedStartsTheNextQueuedPane() {
        let fixture = Self.attachedConnection()
        defer { fixture.close() }

        let limit = RemoteTmuxControlConnection.maximumConcurrentQueuedPaneSeeds
        for paneId in 1...(limit + 3) {
            fixture.connection.queuePaneSeed(paneId: paneId)
        }

        var commandNumber = 40
        var finished = 0
        while finished == 0, let kind = fixture.connection.pendingCommandKindsForTesting.first {
            fixture.connection.handleMessageForTesting(
                .commandResult(commandNumber: commandNumber, lines: Self.reply(to: kind), isError: false))
            commandNumber += 1
            if case .paneState = kind { finished += 1 }
        }

        #expect(fixture.connection.connectionState == .connected)
        #expect(fixture.connection.pendingPaneSeeds.count == limit)
        #expect(fixture.connection.pendingPaneSeeds[1] == nil)
        #expect(fixture.connection.pendingPaneSeeds[limit + 1] != nil)
        #expect(fixture.connection.queuedPaneSeedPaneIDs == [limit + 2, limit + 3])
    }

    @Test func aPaneThatGoesAwayLeavesTheQueue() {
        let fixture = Self.attachedConnection()
        defer { fixture.close() }

        let limit = RemoteTmuxControlConnection.maximumConcurrentQueuedPaneSeeds
        for paneId in 1...(limit + 4) {
            fixture.connection.queuePaneSeed(paneId: paneId)
        }
        // Pane 1 is in flight and pane limit+2 is waiting; both close.
        let live = Set(1...(limit + 4)).subtracting([1, limit + 2])
        fixture.connection.discardPendingPaneSeeds(keeping: live)

        #expect(fixture.connection.pendingPaneSeeds[1] == nil)
        #expect(!fixture.connection.queuedPaneSeedPaneIDs.contains(limit + 2))
        // The freed slot went to the next waiting pane.
        #expect(fixture.connection.pendingPaneSeeds.count == limit)
        #expect(fixture.connection.pendingPaneSeeds[limit + 1] != nil)
    }

    @Test func reconnectingDropsTheQueue() {
        let fixture = Self.attachedConnection()
        defer { fixture.close() }

        for paneId in 1...50 {
            fixture.connection.queuePaneSeed(paneId: paneId)
        }
        fixture.connection.beginReconnecting()

        // The reconnect reseeds every pane it knows, so nothing waits here.
        #expect(fixture.connection.queuedPaneSeedPaneIDs.isEmpty)
        #expect(fixture.connection.queuedPaneSeedIDs.isEmpty)
    }

    private static func reply(to kind: RemoteTmuxControlConnection.CommandKind) -> [String] {
        switch kind {
        case .paneReflow: return ["0|zsh"]
        case .paneAltScreen: return ["0"]
        case .capturePane: return ["prompt"]
        case .paneState:
            return ["cursor_x=0,cursor_y=0,scroll_region_upper=0,scroll_region_lower=23,"
                + "cursor_flag=1,insert_flag=0,keypad_cursor_flag=0,keypad_flag=0,"
                + "wrap_flag=1,origin_flag=0,pane_height=24,mouse_all_flag=0,"
                + "mouse_button_flag=0,mouse_standard_flag=0,mouse_sgr_flag=0,mouse_utf8_flag=0"]
        case .panePath: return ["/tmp"]
        default: return []
        }
    }

    private static func attachedConnection() -> Fixture {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "queued-seed.test"),
            sessionName: "work")
        let pipe = Pipe()
        // Drain like ssh would, so a write never blocks on a full pipe. The writer still
        // only frees budget on the main actor, which a synchronous burst never yields.
        pipe.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-queued-seed-test",
            maxPendingBytes: stdinBudget,
            onFailure: {})
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
        connection.handleMessageForTesting(.commandResult(commandNumber: 1, lines: [], isError: false))
        return Fixture(connection: connection, writer: writer, pipe: pipe)
    }

    private struct Fixture {
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe

        @MainActor func close() {
            connection.stop()
            writer.close()
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }
    }
}
