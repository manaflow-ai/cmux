import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A host with many windows mounts every pane of every mirrored workspace in one
/// main-actor turn. Each pane seed is about a dozen commands and a capture of up to
/// 5,000 lines of history, so the seeds are started a few at a time and their captures
/// do not all arrive at once.
@MainActor
@Suite struct RemoteTmuxQueuedPaneSeedTests {
    /// The control writer's real stdin budget.
    private static let stdinBudget = RemoteTmuxControlConnection.maxPendingStdinBytes

    /// The commands alone, for every pane at once, still fit through a draining pipe: a big
    /// burst is not a dead pipe, so it must not reconnect.
    @Test func seedingEveryPaneAtOnceKeepsTheStreamUp() {
        let fixture = Self.attachedConnection()
        defer { fixture.close() }

        for paneId in 1...1_500 {
            fixture.connection.seedPane(paneId: paneId, clearScrollback: true)
        }

        #expect(fixture.connection.connectionState == .connected)
        #expect(!fixture.connection.snapshot().recentEvents.contains("stdin-write-backpressure"))
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

    /// A seed outside the queue (a repaint or a reconnect reseed) holds the whole seed budget.
    /// When the queue pops a pane the budget refuses, that pane goes to the budget recovery and
    /// the pop stops, leaving the panes behind it waiting. If no queued seed is in flight then,
    /// nothing finishing in the queue will start them, so the recovery has to once the budget
    /// frees.
    @Test func panesWaitingBehindAFullSeedBudgetStartWhenItFrees() async {
        // Measure what the holder seed retains once its capture is in, then size the budget so
        // the holder fits and a queued pane's 11-byte reset prefix does not fit beside it.
        let probe = Self.attachedConnection()
        Self.startHolderSeed(on: probe.connection)
        let holderBytes = probe.connection.pendingPaneSeedByteCount
        probe.close()
        let fixture = Self.attachedConnection(pendingPaneSeedByteLimit: holderBytes + 5)
        defer { fixture.close() }
        var commandNumber = Self.startHolderSeed(on: fixture.connection)
        #expect(fixture.connection.pendingPaneSeedByteCount == holderBytes)

        fixture.connection.queuePaneSeed(paneId: 1)
        #expect(fixture.connection.queuedPaneSeedIDs.isEmpty, "the budget is full, so no queued seed started")
        // Panes 2 to 4 were already waiting behind pane 1 when its pop was refused: the state
        // the queue is left in when the pop stops at a refused pane with no seed in flight.
        fixture.connection.queuedPaneSeedPaneIDs = [2, 3, 4]

        var seeded: Set<Int> = []
        var answered: [String] = []
        // Done once every pane has been seeded, nothing waits and nothing is left to answer.
        let deadline = ContinuousClock.now + .seconds(10)
        func allSeeded() -> Bool {
            seeded.isSuperset(of: [1, 2, 3, 4]) && fixture.connection.queuedPaneSeedPaneIDs.isEmpty
                && fixture.connection.pendingCommandKindsForTesting.isEmpty
        }
        while !allSeeded(), answered.count < 400, ContinuousClock.now < deadline {
            seeded.formUnion(fixture.connection.pendingPaneSeeds.keys)
            if let kind = fixture.connection.pendingCommandKindsForTesting.first {
                // The holder's capture fills the budget; the queued panes' captures are empty.
                let lines: [String]
                if case let .capturePane(paneId, _) = kind {
                    lines = paneId == 99 ? [String(repeating: "x", count: 16)] : []
                } else {
                    lines = Self.reply(to: kind)
                }
                fixture.connection.handleMessageForTesting(
                    .commandResult(commandNumber: commandNumber, lines: lines, isError: false))
                commandNumber += 1
                answered.append(String(describing: kind).prefix(while: { $0 != "(" }).description)
            } else {
                // The budget recovery runs as a main-actor task after the release that frees it.
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        #expect(answered.count < 400, "the replies never ran out: \(answered.suffix(24)) events: \(fixture.connection.snapshot().recentEvents.suffix(30))")
        #expect(fixture.connection.connectionState == .connected)
        #expect(seeded.isSuperset(of: [1, 2, 3, 4]), "seeded: \(seeded.sorted())")
        #expect(fixture.connection.queuedPaneSeedPaneIDs.isEmpty)
    }

    /// Seeds pane 99 outside the queue and delivers its capture, stopping before the state
    /// reply that would finish it. Returns the next command number to answer with.
    @discardableResult
    private static func startHolderSeed(on connection: RemoteTmuxControlConnection) -> Int {
        _ = connection.seedPane(paneId: 99, clearScrollback: true)
        var commandNumber = 40
        while let kind = connection.pendingCommandKindsForTesting.first {
            if case .paneState = kind { break }
            let lines: [String]
            if case .capturePane = kind { lines = [String(repeating: "x", count: 16)] } else { lines = reply(to: kind) }
            connection.handleMessageForTesting(.commandResult(commandNumber: commandNumber, lines: lines, isError: false))
            commandNumber += 1
        }
        return commandNumber
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

    private static func attachedConnection(
        pendingPaneSeedByteLimit: Int = RemoteTmuxControlConnection.maximumPendingPaneSeedBytes
    ) -> Fixture {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "queued-seed.test"),
            sessionName: "work",
            pendingPaneSeedByteLimit: pendingPaneSeedByteLimit)
        let pipe = Pipe()
        // Drain like ssh would, so a write never blocks on a full pipe.
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
