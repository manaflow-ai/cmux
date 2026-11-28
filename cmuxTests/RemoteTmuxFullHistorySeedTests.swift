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
        let sent = try await answerQueriesUntilTheSeedQueue(fixture, shape: "1000 200 0", sampleRow: "sample")
        #expect(sent.shape.contains("display-message -p -t %7"))
        #expect(sent.shape.contains("#{history_size}"))
        let queue = sent.queue
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
        let sent = try await answerQueriesUntilTheSeedQueue(fixture, shape: "120 80 0", sampleRow: "sample")
        #expect(sent.queue.contains("capture-pane -p -e -S - -E -1 -t %7"))

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
        // The sampled rows take 3 bytes each, so the load asks for the newest 13 of the 40.
        _ = try await answerQueriesUntilTheSeedQueue(fixture, shape: "40 6000 0", sampleRow: "s")
        // Older rows can be denser than the sample. These take 10 bytes each, and the seed
        // keeps the newest four that fit.
        replyToSeedQueue(fixture, history: [(1...6).map { String(format: "row-%04d", $0) }])

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
        _ = try await answerQueriesUntilTheSeedQueue(fixture, shape: "20 80 0", sampleRow: "sample")
        replyToSeedQueue(fixture, history: [(1...20).map { String(format: "history-row-%04d", $0) }])

        // Painting the screen without those rows would leave a hole the find bar
        // calls a complete load.
        #expect(await reseed.value == .failed)
    }

    // MARK: - Bytes requested

    @Test(.timeLimit(.minutes(1))) func aWideDenseColorHistoryAsksForNoMoreThanTheSeedKeeps() async throws {
        // 100,000 rows on a 200-column pane where every cell changes its 24-bit foreground
        // and background: over 7 KB a row from `capture-pane -e`, about 700 MB in all. The
        // seed keeps only `maximumFullHistoryBytes` of history, and tmux answers a queue's
        // captures back to back through the stdout bridge, so a byte asked for past what
        // the seed keeps is read only to be dropped.
        let fixture = attachedConnection()
        defer { fixture.close() }
        let row = Self.denseColorRow(width: 200)
        let rowBytes = row.utf8.count + 2

        let reseed = Task { await fixture.connection.reseedPaneWithFullHistory(paneId: 7) }
        let sent = try await answerQueriesUntilTheSeedQueue(fixture, shape: "100000 200 0", sampleRow: row)

        let kept = RemoteTmuxControlConnection.maximumFullHistoryBytes
        let planned = Self.requestedHistoryRows(in: sent.queue, historySize: 100_000) * rowBytes
        let sampled = sent.queries.map { Self.requestedHistoryRows(in: $0, historySize: 100_000) }.reduce(0, +)
            * rowBytes
        #expect(planned <= kept, "the queue asks for \(planned) bytes; the seed keeps \(kept)")
        // Rounded down to whole rows, the plan still fills what the seed keeps.
        #expect(planned > kept - rowBytes, "the queue asks for only \(planned) of \(kept) bytes")
        #expect(
            planned + sampled < RemoteTmuxControlConnection.maxPendingStdoutBytes,
            "the load reads \(planned + sampled) bytes through a \(RemoteTmuxControlConnection.maxPendingStdoutBytes)-byte bridge"
        )

        fixture.connection.beginReconnecting()
        #expect(await reseed.value == .failed)
    }

    // MARK: - A full-screen app starting mid-load

    @Test(.timeLimit(.minutes(1))) func aPaneThatSwitchedToTheAlternateScreenKeepsItsScrollback() async throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var seeds: [RemoteTmuxPaneSeed] = []
        let token = fixture.connection.addObserver(onPaneSeed: { paneID, seed in
            if paneID == 7 { seeds.append(seed) }
        })
        defer { fixture.connection.removeObserver(token) }

        let reseed = Task { await fixture.connection.reseedPaneWithFullHistory(paneId: 7) }
        _ = try await answerQueriesUntilTheSeedQueue(fixture, shape: "40 80 0", sampleRow: "sample")
        // The pane was on the primary screen when its shape was read, and a full-screen
        // app had started by the time tmux ran the queue.
        replyToSeedQueue(fixture, history: [["history-1", "history-2"]], alternateScreen: true)

        #expect(await reseed.value == .alternateScreen)
        // Output was paused for the queue, so its screen still has to be painted, on the
        // alternate screen, which has no scrollback to hold the history rows.
        let painted = String(decoding: try #require(seeds.last).snapshot, as: UTF8.self)
        #expect(painted.hasPrefix("\u{1b}[?1049h"))
        #expect(painted.hasSuffix("screen"))
        #expect(!painted.contains("history-1"))
        // The scrollback the surface already holds stays: there is nothing to replace it.
        #expect(!painted.contains("\u{1b}[3J"))
    }

    // MARK: - The find bar's load state

    @Test(.timeLimit(.minutes(1))) func aPanesLoadOutlivesARebuiltFindBarAndEndsAtTheNextSeed() async throws {
        let fixture = attachedConnection()
        defer { fixture.close() }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let sessionMirror = RemoteTmuxSessionMirror(
            host: fixture.connection.host,
            sessionName: "work",
            connection: fixture.connection,
            tabManager: manager,
            workspace: manager.selectedWorkspace!
        )
        defer { sessionMirror.detachObserver() }
        // No window holds pane 7 here, so the mirror sends nothing of its own and the
        // load's commands are the only ones in the queue.
        #expect(fixture.connection.pendingCommandKindsForTesting.isEmpty)

        let search = sessionMirror.fullHistorySearch(forPane: 7)
        let load = Task { await search.load() }
        _ = try await answerQueriesUntilTheSeedQueue(fixture, shape: "40 80 0", sampleRow: "sample")
        // A find bar rebuilt mid-load (a portal reparent) shows the same load and its spinner.
        #expect(sessionMirror.fullHistorySearch(forPane: 7) === search)
        #expect(search.state == .loading)
        // The load's own seed reaches the mirror before the load finishes, and must not end it.
        replyToSeedQueue(fixture, history: [["history-1", "history-2"]])
        #expect(await load.value)
        #expect(search.state == .loaded(historyRows: 2, truncated: false))

        // A visible-screen repaint leaves the scrollback alone.
        sessionMirror.routeSeed(paneId: 7, seed: Self.seed(.visibleRepaint))
        #expect(search.state == .loaded(historyRows: 2, truncated: false))
        // A reconnect reseed replaces the scrollback with the newest rows again.
        sessionMirror.routeSeed(paneId: 7, seed: Self.seed(.fullHistory))
        #expect(search.state == .notLoaded)
    }

    private static func seed(_ kind: RemoteTmuxPaneSeedKind) -> RemoteTmuxPaneSeed {
        RemoteTmuxPaneSeed(kind: kind, discardedOutput: [], snapshot: Data("rows".utf8), catchUpOutput: [], state: Data())
    }

    /// One row as `capture-pane -e` writes it when every cell changes its 24-bit
    /// foreground and background: an SGR sequence ahead of each character.
    private static func denseColorRow(width: Int) -> String {
        (0..<width).map { cell in
            let red = cell % 256, green = (cell * 7) % 256, blue = (cell * 13) % 256
            return "\u{1b}[38;2;\(red);\(green);\(blue);48;2;\(blue);\(red);\(green)mx"
        }.joined()
    }

    /// The history rows the `capture-pane -S … -E …` commands in `text` ask for.
    private static func requestedHistoryRows(in text: String, historySize: Int) -> Int {
        text.matches(of: #/capture-pane -p -e -S (-\d*) -E (-\d+)/#).map { match in
            let top = match.1 == "-" ? historySize : -(Int(match.1) ?? 0)
            let bottom = -(Int(match.2) ?? 0)
            return max(0, top - bottom + 1)
        }.reduce(0, +)
    }

    /// Answers a reseed's queries until it sends its seed queue: the pane's shape, then
    /// `sampleRow` for every row any other query captures. Returns what it wrote: the
    /// shape query, every other query, and the queue.
    private func answerQueriesUntilTheSeedQueue(
        _ fixture: Fixture,
        shape: String,
        sampleRow: String
    ) async throws -> (shape: String, queries: [String], queue: String) {
        var shapeQuery = ""
        var queries: [String] = []
        var number = 40
        while true {
            try await waitForPendingCommands(on: fixture.connection) { kinds in
                kinds.contains { kind in
                    switch kind {
                    case .rawQuery, .paneState: return true
                    default: return false
                    }
                }
            }
            let text = String(decoding: fixture.pipe.fileHandleForReading.availableData, as: UTF8.self)
            let queued = fixture.connection.pendingCommandKindsForTesting.contains {
                if case .paneState = $0 { return true } else { return false }
            }
            if queued { return (shapeQuery, queries, text) }
            if text.contains("#{history_size}") {
                shapeQuery = text
                fixture.reply(number: number, lines: [shape])
            } else {
                queries.append(text)
                let rows = Self.requestedHistoryRows(in: text, historySize: 0)
                fixture.reply(number: number, lines: Array(repeating: sampleRow, count: rows))
            }
            number += 1
        }
    }

    /// Answers every queued seed command, history chunks in order, starting at
    /// command 41.
    private func replyToSeedQueue(_ fixture: Fixture, history: [[String]], alternateScreen: Bool = false) {
        var number = 41
        var chunks = history[...]
        for kind in fixture.connection.pendingCommandKindsForTesting {
            let lines: [String]
            switch kind {
            case .paneAltScreen: lines = [alternateScreen ? "1" : "0"]
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
        // Answer whatever the attach sent next (the window list, and any subscription), so each
        // test starts from an empty queue.
        var number = 1
        while !connection.pendingCommandKindsForTesting.isEmpty {
            connection.handleMessageForTesting(.commandResult(commandNumber: number, lines: [], isError: false))
            number += 1
        }
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
