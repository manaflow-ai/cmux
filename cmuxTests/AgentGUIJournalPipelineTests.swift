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
        #expect(appended.map(\.seq) == [EntrySeq(rawValue: 2)])

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
        #expect(initial.tailSeq == EntrySeq(rawValue: AgentGUIConstants.initialTailLineCap - 1))

        try append(lines: [Self.codexMessageLine], to: transcript)
        _ = await pipeline.ingestInitial()
        let appended = try #require(pipeline.entries(beforeSeq: nil, afterSeq: nil, limit: 1))
        #expect(appended.entries.last?.seq == EntrySeq(rawValue: AgentGUIConstants.initialTailLineCap))
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
        #expect(page.tailSeq == EntrySeq(rawValue: 500))
        #expect(page.entries.last?.seq == EntrySeq(rawValue: 500))
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
        #expect(page.entries.map(\.seq) == [EntrySeq(rawValue: 0), EntrySeq(rawValue: 1), EntrySeq(rawValue: 2)])
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

    private static let codexToolCallLine = """
    {"type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"shell","arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"echo ok\\"]}"}}
    """

    private static let codexToolOutputLine = """
    {"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"ok","exit_code":0}}
    """

    private static let codexMessageLine = """
    {"type":"response_item","payload":{"type":"message","role":"assistant","content":"done"}}
    """

    private static let codexMessageLineWithMultibyteText = """
    {"type":"response_item","payload":{"type":"message","role":"assistant","content":"caf\u{00E9}"}}
    """

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
