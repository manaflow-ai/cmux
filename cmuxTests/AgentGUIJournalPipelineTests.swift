import CmuxAgentReplica
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AgentGUIJournalPipelineTests {
    @Test func missingJournalIsAnEmptyPageThenResetsWhenCreated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = directory.appendingPathComponent("not-created-yet.jsonl")
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-empty"),
            kind: .codex,
            path: transcript.path
        )

        let emptyEvents = await pipeline.ingestInitial()
        let emptyPage = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 10))
        #expect(emptyPage.entries.isEmpty)
        #expect(emptyPage.tailSeq == EntrySeq(rawValue: 0))
        #expect(emptyPage.windowStart == EntrySeq(rawValue: 0))
        #expect(emptyPage.windowEnd == EntrySeq(rawValue: 0))
        #expect(emptyPage.hasMoreBefore == false)
        guard case .reset(let pendingJournal, let tail)? = emptyEvents.first else {
            Issue.record("missing journal should establish an empty replica journal")
            return
        }
        #expect(tail == EntrySeq(rawValue: 0))

        try write(lines: [Self.codexMessageLine], to: transcript)
        let createdEvents = await pipeline.ingestInitial()
        let createdPage = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 10))
        #expect(createdPage.journalID != pendingJournal)
        #expect(createdPage.entries.count == 1)
        #expect(createdEvents.contains { event in
            if case .reset(let journalID, _) = event { return journalID == createdPage.journalID }
            return false
        })
    }

    @Test func pathThatCannotBeReadDoesNotMasqueradeAsEmpty() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-unreadable-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-unreadable"),
            kind: .codex,
            path: directory.path
        )

        _ = await pipeline.ingestInitial()

        #expect(pipeline.lastReadFailed)
        #expect(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 10) == nil)
    }

    @Test func pairsToolResultsAsReplacementsAndResetsAfterRotation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try write(lines: [Self.codexToolCallLine], to: transcript)

        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-1"),
            kind: .codex,
            path: transcript.path
        )
        let initialEvents = await pipeline.ingestInitial()
        guard case let .reset(initialJournal, initialTail)? = initialEvents.first else {
            return #expect(Bool(false), "initial ingest should reset the journal")
        }
        #expect(initialTail == EntrySeq(rawValue: 0))

        let initialPage = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 10))
        #expect(initialPage.entries.map(\.seq) == [EntrySeq(rawValue: 0)])
        #expect(initialPage.entries.first?.version == EntityVersion(rawValue: 1))

        try append(lines: [Self.codexToolOutputLine, Self.codexMessageLine], to: transcript)
        let deltaEvents = await pipeline.ingestInitial()
        let replaced = deltaEvents.compactMap { event -> EntrySnapshot? in
            if case .replaced(_, let entry) = event { return entry }
            return nil
        }
        let appended = deltaEvents.flatMap { event -> [EntrySnapshot] in
            if case .appended(_, let entries) = event { return entries }
            return []
        }
        #expect(replaced.map(\.seq) == [EntrySeq(rawValue: 0)])
        #expect(replaced.first?.version == EntityVersion(rawValue: 2))
        let messageOffset = (Self.codexToolCallLine + "\n").utf8.count
            + (Self.codexToolOutputLine + "\n").utf8.count
        #expect(appended.map(\.seq) == [EntrySeq(rawValue: messageOffset)])

        try FileManager.default.removeItem(at: transcript)
        try write(lines: [Self.codexMessageLine], to: transcript)
        let rotatedEvents = await pipeline.ingestInitial()
        guard case let .reset(rotatedJournal, rotatedTail)? = rotatedEvents.first else {
            return #expect(Bool(false), "rotated transcript should reset the journal")
        }
        #expect(rotatedJournal != initialJournal)
        #expect(rotatedTail == EntrySeq(rawValue: 0))
    }

    @Test func pagesBackThroughWindowAndKeepsHasMoreBeforeHonest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-paging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = directory.appendingPathComponent("paging.jsonl")
        try write(lines: Array(repeating: Self.codexMessageLine, count: 500), to: transcript)

        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-2"),
            kind: .codex,
            path: transcript.path
        )
        _ = await pipeline.ingestInitial()

        let page1 = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 200))
        #expect(page1.entries.count == 200)
        #expect(page1.hasMoreBefore == true)

        let page2 = try #require(pipeline.entries(beforeSeq: page1.windowStart, afterSeq: nil, limit: 200))
        #expect(page2.entries.count == 200)
        #expect(page2.hasMoreBefore == true)

        let page3 = try #require(pipeline.entries(beforeSeq: page2.windowStart, afterSeq: nil, limit: 200))
        #expect(page3.entries.count == 100)
        #expect(page3.hasMoreBefore == false)

        try append(lines: [Self.codexMessageLine], to: transcript)
        _ = await pipeline.ingestInitial()
        #expect((pipeline.window?.entriesBySeq.count ?? 0) <= AgentGUIConstants.journalWindowEntryCap)
    }

    @Test func initialIngestReadsABoundedTailAndAppendsContiguously() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-bounded-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = directory.appendingPathComponent("bounded.jsonl")
        try write(lines: Array(repeating: Self.codexMessageLine, count: 3_000), to: transcript)
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-bounded"),
            kind: .codex,
            path: transcript.path
        )

        _ = await pipeline.ingestInitial()
        let initial = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 200))
        #expect(pipeline.lastReadByteCount <= AgentGUIConstants.initialTailByteCap)
        #expect(pipeline.window?.entriesBySeq.count == AgentGUIConstants.initialTailLineCap)
        #expect(initial.hasMoreBefore)
        #expect(initial.tailSeq == EntrySeq(rawValue: (3_000 - 1) * Self.messageStride))

        try append(lines: [Self.codexMessageLine], to: transcript)
        _ = await pipeline.ingestInitial()
        let appended = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 1))
        #expect(appended.entries.last?.seq == EntrySeq(rawValue: 3_000 * Self.messageStride))
    }

    @Test func oversizedIncrementalBacklogRebasesFromBoundedTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-bounded-backlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("backlog.jsonl")
        try write(lines: [Self.codexMessageLine], to: transcript)
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-bounded-backlog"),
            kind: .codex,
            path: transcript.path
        )
        _ = await pipeline.ingestInitial()

        let oversizedBookkeeping = #"{"type":"turn_context","payload":{"padding":""#
            + String(repeating: "x", count: AgentGUIConstants.journalIncrementalByteCap + 1_024)
            + #""}}"#
        let trailingLines = (0..<20).map(Self.codexMessageLine(index:))
        try append(lines: [oversizedBookkeeping] + trailingLines, to: transcript)
        let events = await pipeline.ingestInitial()

        #expect(pipeline.lastReadByteCount <= AgentGUIConstants.initialTailByteCap)
        #expect(events.contains { event in
            if case .reset = event { return true }
            return false
        })
        let page = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 50))
        #expect(page.entries.count == trailingLines.count)
        #expect(page.entries.first?.seq.rawValue ?? 0 > AgentGUIConstants.journalIncrementalByteCap)
    }

    @Test func successiveInPlaceTruncationsMintDistinctJournals() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-truncate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = directory.appendingPathComponent("truncate.jsonl")
        try write(lines: [Self.codexMessageLine], to: transcript)

        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-3"),
            kind: .codex,
            path: transcript.path
        )
        let firstReset = await pipeline.ingestInitial()
        guard case let .reset(firstJournal, _)? = firstReset.first else {
            return #expect(Bool(false), "initial ingest should reset the journal")
        }

        try truncateAndRewrite(transcript, lines: [Self.codexToolCallLine])
        let secondReset = await pipeline.ingestInitial()
        guard case let .reset(secondJournal, _)? = secondReset.first else {
            return #expect(Bool(false), "first truncation should reset the journal")
        }
        #expect(secondJournal != firstJournal)

        try truncateAndRewrite(transcript, lines: [Self.codexToolOutputLine])
        let thirdReset = await pipeline.ingestInitial()
        guard case let .reset(thirdJournal, _)? = thirdReset.first else {
            return #expect(Bool(false), "second truncation should reset the journal")
        }
        #expect(thirdJournal != secondJournal)
        #expect(thirdJournal != firstJournal)
    }

    @Test func concurrentIngestsShareOneReadPass() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = directory.appendingPathComponent("concurrent.jsonl")
        try write(lines: Array(repeating: Self.codexMessageLine, count: 500), to: transcript)
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-4"),
            kind: .codex,
            path: transcript.path
        )

        async let firstIngest = pipeline.ingestInitial()
        async let secondIngest = pipeline.ingestInitial()
        _ = await (firstIngest, secondIngest)

        try append(lines: [Self.codexMessageLine], to: transcript)
        _ = await pipeline.ingestInitial()
        let page = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 200))
        #expect(page.tailSeq == EntrySeq(rawValue: 500 * Self.messageStride))
        #expect(page.entries.last?.seq == EntrySeq(rawValue: 500 * Self.messageStride))
    }

    @Test func stableHeadShrinkResetsBeforeRegrowth() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-shrink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = directory.appendingPathComponent("shrink.jsonl")
        try write(lines: Array(repeating: Self.codexMessageLine, count: 3), to: transcript)
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-5"),
            kind: .codex,
            path: transcript.path
        )
        let initialEvents = await pipeline.ingestInitial()
        guard case let .reset(initialJournal, _)? = initialEvents.first else {
            return #expect(Bool(false), "initial ingest should reset the journal")
        }

        try truncateAndRewrite(transcript, lines: [Self.codexMessageLine])
        let shrinkEvents = await pipeline.ingestInitial()
        guard case let .reset(shrunkenJournal, _)? = shrinkEvents.first else {
            return #expect(Bool(false), "same-head shrink should reset the journal")
        }
        #expect(shrunkenJournal != initialJournal)

        try append(lines: [Self.codexMessageLine, Self.codexMessageLine], to: transcript)
        _ = await pipeline.ingestInitial()
        let page = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 10))
        #expect(page.entries.map(\.seq) == [
            EntrySeq(rawValue: 0),
            EntrySeq(rawValue: Self.messageStride),
            EntrySeq(rawValue: 2 * Self.messageStride),
        ])
    }

    @Test func buffersSplitUTF8ScalarUntilLineCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-utf8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = directory.appendingPathComponent("utf8.jsonl")
        try write(lines: [Self.codexMessageLine], to: transcript)
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-6"),
            kind: .codex,
            path: transcript.path
        )
        _ = await pipeline.ingestInitial()

        let line = Self.codexMessageLineWithMultibyteText
        let bytes = Data(line.utf8)
        let leadIndex = try #require(bytes.firstIndex(of: 0xC3))
        let splitIndex = bytes.index(after: leadIndex)
        try append(data: Data(bytes[..<splitIndex]), to: transcript)
        let partialEvents = await pipeline.ingestInitial()
        #expect(partialEvents.isEmpty)

        var remainder = Data(bytes[splitIndex...])
        remainder.append(0x0A)
        try append(data: remainder, to: transcript)
        _ = await pipeline.ingestInitial()

        let page = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 10))
        let entry = try #require(page.entries.last)
        guard case .agentProse(let prose) = entry.content.payload else {
            Issue.record("completed multibyte line should decode as agent prose")
            return
        }
        #expect(prose.markdown == "caf\u{00E9}")
    }

    @Test func diskPagingTraversesHistoryBeyondTheMemoryWindow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-disk-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("long.jsonl")
        let lines = (0..<10_000).map(Self.codexMessageLine(index:))
        var nextOffset = 0
        let expectedOffsets = lines.map { line in
            defer { nextOffset += (line + "\n").utf8.count }
            return nextOffset
        }
        try write(lines: lines, to: transcript)
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-disk-pages"),
            kind: .codex,
            path: transcript.path
        )
        _ = await pipeline.ingestInitial()
        #expect(pipeline.window?.entriesBySeq.count == AgentGUIConstants.journalWindowEntryCap)

        var page = try #require(await pipeline.diskEntries(direction: .tail, limit: 200))
        var pageCount = 1
        var observedOffsets = page.entries.map(\.seq.rawValue)
        while page.hasMoreBefore {
            let previousStart = page.startOffset
            page = try #require(await pipeline.diskEntries(direction: .before(previousStart), limit: 200))
            #expect(page.startOffset < previousStart)
            observedOffsets.append(contentsOf: page.entries.map(\.seq.rawValue))
            pageCount += 1
            #expect(pageCount <= 60)
        }

        #expect(pageCount == 50)
        #expect(observedOffsets.count == 10_000)
        #expect(Set(observedOffsets).count == 10_000)
        #expect(observedOffsets.sorted() == expectedOffsets)
    }

    @Test func pageContextPairsToolResultAtAnExactPageBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-pair-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("pair.jsonl")
        try write(lines: [Self.codexToolCallLine, Self.codexToolOutputLine, Self.codexMessageLine], to: transcript)
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-pair-page"),
            kind: .codex,
            path: transcript.path
        )
        _ = await pipeline.ingestInitial()

        let callEnd = (Self.codexToolCallLine + "\n").utf8.count
        let page = try #require(await pipeline.diskEntries(direction: .after(callEnd), limit: 1))
        let entry = try #require(page.entries.first)
        guard case .toolRun(let tool) = entry.content.payload else {
            Issue.record("tool result at the page boundary should remain a correlated tool row")
            return
        }
        #expect(entry.seq == EntrySeq(rawValue: 0))
        #expect(tool.toolCallID == "call-1")
        #expect(tool.output == "ok")
        #expect(!tool.isRunning)

        let claudeTranscript = directory.appendingPathComponent("claude-pair.jsonl")
        try write(lines: [Self.claudeToolCallLine, Self.claudeToolOutputLine], to: claudeTranscript)
        let claudePipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-claude-pair-page"),
            kind: .claude,
            path: claudeTranscript.path
        )
        _ = await claudePipeline.ingestInitial()
        let claudeCallEnd = (Self.claudeToolCallLine + "\n").utf8.count
        let claudePage = try #require(await claudePipeline.diskEntries(direction: .after(claudeCallEnd), limit: 1))
        let claudeEntry = try #require(claudePage.entries.first)
        guard case .toolRun(let claudeTool) = claudeEntry.content.payload else {
            Issue.record("Claude tool result at the page boundary should remain correlated")
            return
        }
        #expect(claudeEntry.seq == EntrySeq(rawValue: 0))
        #expect(claudeTool.toolCallID == "tool-1")
        #expect(claudeTool.output == "ok")
    }

    @Test func targetedLookupPairsToolResultsBeyondBoundedOverlapInBothDirections() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-far-pair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let codexBookkeeping = #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#
        let codexLines = [Self.codexToolCallLine]
            + Array(repeating: codexBookkeeping, count: 3_000)
            + [Self.codexToolOutputLine, Self.codexMessageLine]
        let codexResultStart = codexLines.dropLast(2).reduce(0) { $0 + ($1 + "\n").utf8.count }
        let codexResultEnd = codexResultStart + (Self.codexToolOutputLine + "\n").utf8.count
        let codexTranscript = directory.appendingPathComponent("codex-far.jsonl")
        try write(lines: codexLines, to: codexTranscript)
        let codexPipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-codex-far"),
            kind: .codex,
            path: codexTranscript.path
        )
        _ = await codexPipeline.ingestInitial()

        for direction in [
            AgentGUIJournalPageDirection.after(codexResultStart),
            .before(codexResultEnd),
        ] {
            let page = try #require(await codexPipeline.diskEntries(direction: direction, limit: 1))
            let entry = try #require(page.entries.first)
            guard case .toolRun(let tool) = entry.content.payload else {
                Issue.record("far Codex result should retain its original tool payload")
                continue
            }
            #expect(entry.seq == EntrySeq(rawValue: 0))
            #expect(tool.toolCallID == "call-1")
            #expect(tool.toolName == "shell")
            #expect(tool.output == "ok")
            #expect(tool.status == "succeeded")
        }

        let claudeBookkeeping = #"{"type":"queue-operation","operation":"enqueue"}"#
        let claudeLines = [Self.claudeToolCallLine]
            + Array(repeating: claudeBookkeeping, count: 3_000)
            + [Self.claudeToolOutputLine]
        let claudeResultStart = claudeLines.dropLast().reduce(0) { $0 + ($1 + "\n").utf8.count }
        let claudeResultEnd = claudeResultStart + (Self.claudeToolOutputLine + "\n").utf8.count
        let claudeTranscript = directory.appendingPathComponent("claude-far.jsonl")
        try write(lines: claudeLines, to: claudeTranscript)
        let claudePipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-claude-far"),
            kind: .claude,
            path: claudeTranscript.path
        )
        _ = await claudePipeline.ingestInitial()

        for direction in [
            AgentGUIJournalPageDirection.after(claudeResultStart),
            .before(claudeResultEnd),
        ] {
            let page = try #require(await claudePipeline.diskEntries(direction: direction, limit: 1))
            let entry = try #require(page.entries.first)
            guard case .toolRun(let tool) = entry.content.payload else {
                Issue.record("far Claude result should retain its original tool payload")
                continue
            }
            #expect(entry.seq == EntrySeq(rawValue: 0))
            #expect(tool.toolCallID == "tool-1")
            #expect(tool.toolName == "Bash")
            #expect(tool.output == "ok")
            #expect(tool.status == "succeeded")
        }
    }

    @Test func missingToolCallLookupStopsAtBudgetAndResultRemainsVisible() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-tool-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("tool-budget.jsonl")
        let separator = #"{"type":"turn_context","payload":{"padding":""#
            + String(repeating: "x", count: AgentGUIJournalToolCallLocator.scanByteCap + 1_024 * 1_024)
            + #""}}"#
        let resultStart = (Self.codexToolCallLine + "\n").utf8.count
            + (separator + "\n").utf8.count
        try write(lines: [Self.codexToolCallLine, separator, Self.codexToolOutputLine], to: transcript)

        let lookup = AgentGUIJournalToolCallLocator.locate(
            callIDs: Set(["call-1"]),
            path: transcript.path,
            before: resultStart
        )
        #expect(lookup.linesByCallID["call-1"] == nil)
        #expect(lookup.scannedByteCount <= AgentGUIJournalToolCallLocator.scanByteCap)
        #expect(lookup.pageCount <= AgentGUIJournalToolCallLocator.scanPageCap)

        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-tool-budget"),
            kind: .codex,
            path: transcript.path
        )
        _ = await pipeline.ingestInitial()
        let page = try #require(await pipeline.diskEntries(direction: .after(resultStart), limit: 1))
        guard case .toolRun(let tool) = page.entries.first?.content.payload else {
            Issue.record("unresolved result should remain visible as a structured diagnostic tool row")
            return
        }
        #expect(tool.toolCallID == "call-1")
        #expect(tool.output == "ok")
        #expect(tool.status == "unpaired_result:succeeded")
    }

    @Test func claudeMixedRecordKeepsProseAndIndependentlyReplacesTwoTools() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-mixed-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("mixed.jsonl")
        let callLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will run both."},{"type":"tool_use","id":"tool_a","name":"Bash","input":{"command":"echo a"}},{"type":"tool_use","id":"tool_b","name":"Bash","input":{"command":"echo b"}}]}}"#
        let resultA = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_a","content":"result a","is_error":false}]}}"#
        let resultB = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_b","content":"result b","is_error":false}]}}"#
        try write(lines: [callLine, resultA, resultB], to: transcript)
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-mixed-record"),
            kind: .claude,
            path: transcript.path
        )

        _ = await pipeline.ingestInitial()
        let page = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 10))

        #expect(page.entries.map(\.seq.rawValue) == [0, 1, 2])
        guard case .agentProse(let prose) = page.entries[0].content.payload,
              case .toolRun(let toolA) = page.entries[1].content.payload,
              case .toolRun(let toolB) = page.entries[2].content.payload else {
            Issue.record("mixed Claude source record should preserve prose and both tools")
            return
        }
        #expect(prose.markdown == "I will run both.")
        #expect(toolA.toolCallID == "tool_a")
        #expect(toolA.output == "result a")
        #expect(toolB.toolCallID == "tool_b")
        #expect(toolB.output == "result b")
        #expect(page.entries[1].version == EntityVersion(rawValue: 2))
        #expect(page.entries[2].version == EntityVersion(rawValue: 2))

        let head = try #require(await pipeline.diskEntries(direction: .head, limit: 1))
        #expect(head.entries.map(\.seq.rawValue) == [0, 1, 2])
        #expect(head.entries.allSatisfy { $0.version == EntityVersion(rawValue: 1) })
        #expect(head.endOffset == (callLine + "\n").utf8.count)

        let firstResult = try #require(await pipeline.diskEntries(direction: .after(head.endOffset), limit: 1))
        #expect(firstResult.entries.map(\.seq.rawValue) == [1])
        #expect(firstResult.entries.first?.version == EntityVersion(rawValue: 2))
        let secondResult = try #require(await pipeline.diskEntries(direction: .after(firstResult.endOffset), limit: 1))
        #expect(secondResult.entries.map(\.seq.rawValue) == [2])
        #expect(secondResult.entries.first?.version == EntityVersion(rawValue: 2))
    }

    @Test func pathologicalCompositeRecordIsCappedWithVisibleDiagnostic() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-composite-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("composite.jsonl")
        let blocks = (0..<700).map { #"{"type":"text","text":"block \#($0)"}"# }
        let line = #"{"type":"assistant","message":{"role":"assistant","content":["#
            + blocks.joined(separator: ",")
            + #"]}}"#
        try write(lines: [line], to: transcript)
        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-composite-cap"),
            kind: .claude,
            path: transcript.path
        )

        _ = await pipeline.ingestInitial()
        let page = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 600))

        #expect(page.entries.count == AgentGUIConstants.maxEntriesLimit)
        #expect(page.entries.count <= AgentGUIConstants.journalWindowEntryCap)
        guard case .unknown(let diagnostic) = page.entries.last?.content.payload else {
            Issue.record("truncated composite record should end in a visible diagnostic row")
            return
        }
        #expect(diagnostic.rawKind == "source_record_entries_truncated")
    }

    @Test func boundedOversizedRecordsDecodeWithoutSilentCursorSkip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-page-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("progress.jsonl")
        let oversized = #"{"type":"turn_context","padding":""#
            + String(repeating: "x", count: 2_048)
            + #""}"#
        try write(lines: [oversized, Self.codexMessageLine], to: transcript)

        let first = AgentGUIJournalPageReader.read(
            path: transcript.path,
            direction: .head,
            lineLimit: 1,
            byteLimit: 64
        )
        #expect(first.lines.map(\.text) == [oversized])
        #expect(first.endOffset > 0)
        let backward = AgentGUIJournalPageReader.read(
            path: transcript.path,
            direction: .before(first.endOffset),
            lineLimit: 1,
            byteLimit: 64
        )
        #expect(backward.lines.map(\.text) == [oversized])
        #expect(backward.startOffset == 0)
        #expect(backward.endOffset == first.endOffset)
        let next = AgentGUIJournalPageReader.read(
            path: transcript.path,
            direction: .after(first.endOffset),
            lineLimit: 1,
            byteLimit: 1_024
        )
        #expect(next.lines.map(\.text) == [Self.codexMessageLine])
    }

    @Test func recordsBeyondMaximumReadCapEmitVisibleDiagnosticInBothDirections() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-record-diagnostic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("diagnostic.jsonl")
        let unsupported = #"{"type":"turn_context","padding":""#
            + String(repeating: "x", count: AgentGUIJournalPageReader.maximumRecordByteCount + 1)
            + #""}"#
        try write(lines: [unsupported, Self.codexMessageLine], to: transcript)
        let unsupportedEnd = (unsupported + "\n").utf8.count

        let forward = AgentGUIJournalPageReader.read(
            path: transcript.path,
            direction: .head,
            lineLimit: 1,
            byteLimit: 64
        )
        let backward = AgentGUIJournalPageReader.read(
            path: transcript.path,
            direction: .before(unsupportedEnd),
            lineLimit: 1,
            byteLimit: 64
        )
        #expect(forward.lines.first?.text.contains("cmux_oversized_record") == true)
        #expect(backward.lines.first?.text.contains("cmux_oversized_record") == true)
        #expect(forward.endOffset == unsupportedEnd)
        #expect(backward.startOffset == 0)

        let pipeline = AgentGUIJournalPipeline(
            sessionID: AgentSessionID(rawValue: "session-record-diagnostic"),
            kind: .codex,
            path: transcript.path
        )
        _ = await pipeline.ingestInitial()
        let page = try #require(await pipeline.diskEntries(direction: .head, limit: 1))
        guard case .unknown(let diagnostic) = page.entries.first?.content.payload else {
            Issue.record("unsupported source record should become a visible GUI diagnostic")
            return
        }
        #expect(diagnostic.rawKind == "cmux_oversized_record")
    }

    @Test func backwardReaderKeepsFirstLineWhenByteLimitStartsAtBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gui-page-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("boundary.jsonl")
        let lines = ["first", "second", "third", "fourth"]
        try write(lines: lines, to: transcript)
        let suffixByteCount = (lines[2] + "\n" + lines[3] + "\n").utf8.count
        let fileSize = try #require(
            FileManager.default.attributesOfItem(atPath: transcript.path)[.size] as? NSNumber
        ).intValue

        let page = AgentGUIJournalPageReader.read(
            path: transcript.path,
            direction: .before(fileSize),
            lineLimit: 10,
            byteLimit: suffixByteCount
        )

        #expect(page.readSucceeded)
        #expect(page.lines.map(\.text) == ["third", "fourth"])
        #expect(page.startOffset == fileSize - suffixByteCount)
        #expect(page.endOffset == fileSize)
    }

    @Test func staleJournalAndInvalidCursorResolveToAuthoritativeTailRestart() {
        let current = JournalID(rawValue: "current")
        let stale = JournalID(rawValue: "stale")
        let staleResolution = AgentGUIService.resolvePageRequest(
            anchor: .before,
            cursor: AgentGUIJournalCursorCodec.encode(journalID: stale, byteOffset: 100),
            expectedJournalID: stale,
            currentJournalID: current
        )
        #expect(staleResolution == AgentGUIService.ResolvedPageRequest(
            direction: .tail,
            requiresPagingRestart: true
        ))
        let invalidResolution = AgentGUIService.resolvePageRequest(
            anchor: .after,
            cursor: JournalCursor(rawValue: "not-a-cursor"),
            expectedJournalID: current,
            currentJournalID: current
        )
        #expect(invalidResolution.direction == .tail)
        #expect(invalidResolution.requiresPagingRestart)
    }

    private static let codexToolCallLine = """
    {"type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"shell","arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"echo ok\\"]}"}}
    """

    private static let codexToolOutputLine = """
    {"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"ok","exit_code":0}}
    """

    private static let claudeToolCallLine = """
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"echo ok"}}]}}
    """

    private static let claudeToolOutputLine = """
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok","is_error":false}]}}
    """

    private static let codexMessageLine = """
    {"type":"response_item","payload":{"type":"message","role":"assistant","content":"done"}}
    """

    private static func codexMessageLine(index: Int) -> String {
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":"entry \#(index)"}}"#
    }

    private static let codexMessageLineWithMultibyteText = """
    {"type":"response_item","payload":{"type":"message","role":"assistant","content":"caf\u{00E9}"}}
    """

    private static var messageStride: Int {
        (codexMessageLine + "\n").utf8.count
    }

    private func write(lines: [String], to url: URL) throws {
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func append(data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func truncateAndRewrite(_ url: URL, lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
