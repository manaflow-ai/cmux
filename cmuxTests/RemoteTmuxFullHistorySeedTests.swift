import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Loading a mirrored pane's whole tmux history into its surface, so the
/// surface's own find (and copy-mode `/`, `n`, `N`) can reach rows older than
/// the attach seed.
@MainActor
@Suite struct RemoteTmuxFullHistorySeedTests {
    // MARK: - Chunk plan

    @Test func historyIsReadOldestFirstInChunksThatEndAtTheNewestRow() {
        let plan = RemoteTmuxPaneHistoryPlan(historySize: 5_000, paneWidth: 200, maximumChunkCells: 400_000)
        #expect(plan.chunks == [
            .init(start: "-", end: "-3001"),
            .init(start: "-3000", end: "-1001"),
            .init(start: "-1000", end: "-1"),
        ])
        #expect(plan.historyRows == 5_000)
        #expect(!plan.isTruncated)
    }

    @Test func aWidePaneGetsShorterChunks() {
        let plan = RemoteTmuxPaneHistoryPlan(historySize: 300, paneWidth: 1_000)
        // 131,072 cells per chunk at 1,000 columns is 131 rows.
        #expect(plan.chunks.map(\.end) == ["-170", "-39", "-1"])
        #expect(plan.chunks.first?.start == "-")
    }

    @Test func historyPastTheCapStartsAtTheCapAndSaysSo() {
        let plan = RemoteTmuxPaneHistoryPlan(historySize: 250_000, paneWidth: 100)
        #expect(plan.historyRows == RemoteTmuxPaneHistoryPlan.maximumRows)
        #expect(plan.isTruncated)
        #expect(plan.chunks.first?.start == "-\(RemoteTmuxPaneHistoryPlan.maximumRows)")
        #expect(plan.chunks.last?.end == "-1")
    }

    @Test func aChunkOfTheDensestColorOutputFitsInOneCommandBlock() {
        // tmux 3.7 writes 55 bytes per cell from `capture-pane -e` when every cell
        // changes bold, italic, underline, strikethrough and its 24-bit foreground,
        // background and underline colors. The stream resets on a block over the
        // parser's limit, so a chunk of such cells must stay under it.
        let measuredBytesPerCell = 55
        for width in [80, 200, 500, 1_000, 10_000] {
            let historySize = 100_000
            let plan = RemoteTmuxPaneHistoryPlan(historySize: historySize, paneWidth: width)
            for chunk in plan.chunks {
                let top = chunk.start == "-" ? historySize : -(Int(chunk.start) ?? 0)
                let bottom = -(Int(chunk.end) ?? 0)
                let bytes = (top - bottom + 1) * width * measuredBytesPerCell
                #expect(
                    bytes < RemoteTmuxControlStreamParser.defaultMaximumCommandBlockBytes,
                    "width \(width): chunk \(chunk.captureArguments) can be \(bytes) bytes"
                )
            }
        }
    }

    @Test func aPaneWithNoHistoryNeedsNoChunk() {
        let plan = RemoteTmuxPaneHistoryPlan(historySize: 0, paneWidth: 80)
        #expect(plan.chunks.isEmpty)
        #expect(plan.historyRows == 0)
    }

    // MARK: - Reseed over the control stream

    @Test(.timeLimit(.minutes(1))) func fullHistoryReseedPaintsEveryHistoryRowBeforeTheScreen() async throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var seeds: [RemoteTmuxPaneSeed] = []
        let token = fixture.connection.addObserver(onPaneSeed: { paneID, seed in
            if paneID == 7 { seeds.append(seed) }
        })
        defer { fixture.connection.removeObserver(token) }

        let reseed = Task { await fixture.connection.reseedPaneWithFullHistory(paneId: 7) }
        try await waitForPendingCommands(on: fixture.connection) { kinds in
            kinds.contains { if case .rawQuery = $0 { return true } else { return false } }
        }
        let query = String(decoding: fixture.pipe.fileHandleForReading.availableData, as: UTF8.self)
        #expect(query.contains("display-message -p -t %7"))
        #expect(query.contains("#{history_size}"))
        fixture.reply(number: 40, lines: ["1000 200 0"])

        try await waitForPendingCommands(on: fixture.connection) { kinds in
            kinds.contains { if case .paneState = $0 { return true } else { return false } }
        }
        let queue = String(decoding: fixture.pipe.fileHandleForReading.availableData, as: UTF8.self)
        // One tmux command queue: pane output stays paused across every capture.
        #expect(queue.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 1)
        let pause = try #require(queue.range(of: "refresh-client -A \"%7:pause\""))
        let oldest = try #require(queue.range(of: "capture-pane -p -e -S - -E -346 -t %7"))
        let newest = try #require(queue.range(of: "capture-pane -p -e -S -345 -E -1 -t %7"))
        let screen = try #require(queue.range(of: "capture-pane -p -e -t %7"))
        let resume = try #require(queue.range(of: "refresh-client -A \"%7:continue\""))
        #expect(pause.lowerBound < oldest.lowerBound)
        #expect(oldest.lowerBound < newest.lowerBound)
        #expect(newest.lowerBound < screen.lowerBound)
        #expect(screen.lowerBound < resume.lowerBound)

        var number = 41
        var historyChunk = 0
        for kind in fixture.connection.pendingCommandKindsForTesting {
            let lines: [String]
            switch kind {
            case .paneAltScreen:
                lines = ["0"]
            case .capturePaneHistory:
                historyChunk += 1
                lines = ["history-\(historyChunk)-a", "history-\(historyChunk)-b"]
            case .capturePane:
                lines = ["screen-top", "screen-prompt"]
            case .paneState:
                lines = [Self.paneStateLine(cursorX: 13, cursorY: 1)]
            default:
                lines = []
            }
            fixture.reply(number: number, lines: lines)
            number += 1
        }

        let outcome = await reseed.value
        // The outcome counts the rows painted, here the two the stub sent per chunk.
        #expect(outcome == .loaded(historyRows: 4, truncated: false))
        #expect(historyChunk == 2)
        let seed = try #require(seeds.last)
        #expect(seed.kind == .fullHistory)
        let painted = String(decoding: seed.snapshot, as: UTF8.self)
        // The local scrollback is cleared first, then history and screen are
        // written as one run of rows so the history scrolls into scrollback.
        #expect(painted.hasPrefix("\u{1b}[H\u{1b}[2J\u{1b}[3J"))
        let rows = try #require(painted.components(separatedBy: "\u{1b}[H\u{1b}[2J").last)
        #expect(rows == [
            "history-1-a", "history-1-b", "history-2-a", "history-2-b",
            "screen-top", "screen-prompt",
        ].joined(separator: "\r\n"))
    }

    @Test(.timeLimit(.minutes(1))) func aPaneOnTheAlternateScreenIsNotCaptured() async throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        let reseed = Task { await fixture.connection.reseedPaneWithFullHistory(paneId: 7) }
        try await waitForPendingCommands(on: fixture.connection) { !$0.isEmpty }
        _ = fixture.pipe.fileHandleForReading.availableData
        fixture.reply(number: 40, lines: ["0 80 1"])

        #expect(await reseed.value == .alternateScreen)
        #expect(fixture.connection.pendingCommandKindsForTesting.isEmpty)
        #expect(fixture.connection.pendingPaneSeeds.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aStreamResetEndsThePendingReseed() async throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        let reseed = Task { await fixture.connection.reseedPaneWithFullHistory(paneId: 7) }
        try await waitForPendingCommands(on: fixture.connection) { !$0.isEmpty }
        fixture.reply(number: 40, lines: ["120 80 0"])
        try await waitForPendingCommands(on: fixture.connection) { kinds in
            kinds.contains { if case .capturePaneHistory = $0 { return true } else { return false } }
        }

        fixture.connection.beginReconnecting()

        #expect(await reseed.value == .failed)
    }

    @Test(.timeLimit(.minutes(1))) func historyOverTheByteBudgetKeepsTheNewestRows() async throws {
        // Each history row here is 10 bytes with its CR LF; a 40-byte budget holds four.
        let fixture = attachedConnection(fullHistoryByteBudget: 40)
        defer { fixture.close() }

        var seeds: [RemoteTmuxPaneSeed] = []
        let token = fixture.connection.addObserver(onPaneSeed: { paneID, seed in
            if paneID == 7 { seeds.append(seed) }
        })
        defer { fixture.connection.removeObserver(token) }

        let reseed = Task { await fixture.connection.reseedPaneWithFullHistory(paneId: 7) }
        try await waitForPendingCommands(on: fixture.connection) { !$0.isEmpty }
        // 40 rows on a 10,000-column pane read as two chunks (32 rows is the minimum).
        fixture.reply(number: 40, lines: ["40 10000 0"])
        try await waitForPendingCommands(on: fixture.connection) { kinds in
            kinds.contains { if case .paneState = $0 { return true } else { return false } }
        }
        replyToSeedQueue(fixture, history: [["row-0001", "row-0002", "row-0003"], ["row-0004", "row-0005", "row-0006"]])

        #expect(await reseed.value == .loaded(historyRows: 4, truncated: true))
        let painted = String(decoding: try #require(seeds.last).snapshot, as: UTF8.self)
        let rows = try #require(painted.components(separatedBy: "\u{1b}[H\u{1b}[2J").last)
        #expect(rows == ["row-0003", "row-0004", "row-0005", "row-0006", "screen"].joined(separator: "\r\n"))
    }

    @Test(.timeLimit(.minutes(1))) func aHistoryChunkThatCannotBeHeldFailsTheLoad() async throws {
        // 64 bytes holds the clears and the screen but not this history chunk.
        let fixture = attachedConnection(pendingPaneSeedByteLimit: 64)
        defer { fixture.close() }

        let reseed = Task { await fixture.connection.reseedPaneWithFullHistory(paneId: 7) }
        try await waitForPendingCommands(on: fixture.connection) { !$0.isEmpty }
        fixture.reply(number: 40, lines: ["20 80 0"])
        try await waitForPendingCommands(on: fixture.connection) { kinds in
            kinds.contains { if case .paneState = $0 { return true } else { return false } }
        }
        replyToSeedQueue(fixture, history: [(1...20).map { String(format: "history-row-%04d", $0) }])

        // Painting the screen without those rows would leave a hole the find bar
        // calls a complete load.
        #expect(await reseed.value == .failed)
    }

    /// Answers every queued seed command, history chunks in order, starting at
    /// command 41.
    private func replyToSeedQueue(_ fixture: Fixture, history: [[String]]) {
        var number = 41
        var chunks = history[...]
        for kind in fixture.connection.pendingCommandKindsForTesting {
            let lines: [String]
            switch kind {
            case .paneAltScreen: lines = ["0"]
            case .capturePaneHistory: lines = chunks.popFirst() ?? []
            case .capturePane: lines = ["screen"]
            case .paneState: lines = [Self.paneStateLine(cursorX: 0, cursorY: 0)]
            default: lines = []
            }
            fixture.reply(number: number, lines: lines)
            number += 1
        }
    }

    // MARK: - Fixture

    private func waitForPendingCommands(
        on connection: RemoteTmuxControlConnection,
        until condition: ([RemoteTmuxControlCommandKind]) -> Bool
    ) async throws {
        // The reseed runs on the main actor too; sleeping hands it the turn it
        // needs to send its next command. Bounded by the clock so a regression fails.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition(connection.pendingCommandKindsForTesting) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if condition(connection.pendingCommandKindsForTesting) { return }
        Issue.record("pending commands never matched: \(connection.pendingCommandKindsForTesting)")
        throw CancellationError()
    }

    private static func paneStateLine(cursorX: Int, cursorY: Int) -> String {
        "cursor_x=\(cursorX),cursor_y=\(cursorY),"
            + "scroll_region_upper=0,scroll_region_lower=23,"
            + "cursor_flag=1,insert_flag=0,keypad_cursor_flag=0,keypad_flag=0,"
            + "wrap_flag=1,origin_flag=0,pane_height=24,"
            + "mouse_all_flag=0,mouse_button_flag=0,mouse_standard_flag=0,"
            + "mouse_sgr_flag=0,mouse_utf8_flag=0"
    }

    private func attachedConnection(
        pendingPaneSeedByteLimit: Int = RemoteTmuxControlConnection.maximumPendingPaneSeedBytes,
        fullHistoryByteBudget: Int = RemoteTmuxControlConnection.maximumFullHistoryBytes
    ) -> Fixture {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "full-history.test"),
            sessionName: "work",
            pendingPaneSeedByteLimit: pendingPaneSeedByteLimit
        )
        connection.fullHistorySeeds.byteBudget = fullHistoryByteBudget
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-full-history-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
        connection.handleMessageForTesting(.commandResult(commandNumber: 1, lines: [], isError: false))
        _ = pipe.fileHandleForReading.availableData
        return Fixture(connection: connection, writer: writer, pipe: pipe)
    }

    private struct Fixture {
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe

        @MainActor func reply(number: Int, lines: [String]) {
            connection.handleMessageForTesting(
                .commandResult(commandNumber: number, lines: lines, isError: false)
            )
        }

        @MainActor func close() {
            connection.stop()
            writer.close()
            try? pipe.fileHandleForReading.close()
        }
    }
}
