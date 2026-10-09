import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Fixture lines follow the Claude Code 2.1 transcript format the upstream
/// `ClaudeTranscriptParser` tests use.
@Suite("Agent session search transcript")
struct AgentSessionSearchTranscriptTests {
    @Test
    func readsPromptsRepliesAndToolTrafficNewestFirst() throws {
        try withTranscript([
            Self.userLine(uuid: "u-1", content: "check the delphi token spend"),
            Self.assistantLine(uuid: "a-1", blocks: [["type": "text", "text": "Reading the cost sheet."]]),
            Self.userLine(uuid: "u-2", content: "now draft the ticket"),
        ]) { url in
            var transcript = AgentSessionSearchTranscript(path: url.path, agentKind: .claude)
            let changed1 = transcript.refresh()
            #expect(changed1)
            let lines = transcript.text.documentText.components(separatedBy: "\n")
            #expect(lines == [
                "check the delphi token spend",
                "now draft the ticket",
                "check the delphi token spend",
                "Reading the cost sheet.",
            ])
        }
    }

    @Test
    func refreshReadsOnlyAppendedCompleteLines() throws {
        try withTranscript([Self.userLine(uuid: "u-1", content: "first ask")]) { url in
            var transcript = AgentSessionSearchTranscript(path: url.path, agentKind: .claude)
            let changed2 = transcript.refresh()
            #expect(changed2)
            let changed3 = transcript.refresh()
            #expect(!changed3)

            let partial = Self.userLine(uuid: "u-2", content: "second ask about deeptune")
            try Self.append(Data(partial.utf8), to: url)
            let changed4 = transcript.refresh()
            #expect(!changed4)
            #expect(!transcript.text.documentText.contains("deeptune"))

            try Self.append(Data("\n".utf8), to: url)
            let changed5 = transcript.refresh()
            #expect(changed5)
            #expect(transcript.text.documentText.contains("second ask about deeptune"))
        }
    }

    @Test
    func toolOutputArrivingLaterIsAdded() throws {
        try withTranscript([
            Self.assistantLine(uuid: "a-1", blocks: [
                ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "grep -r access ."]],
            ]),
        ]) { url in
            var transcript = AgentSessionSearchTranscript(path: url.path, agentKind: .claude)
            let changed6 = transcript.refresh()
            #expect(changed6)
            #expect(transcript.text.documentText.contains("grep -r access"))

            try Self.append(Data((Self.toolResultLine(toolUseID: "toolu_1", content: "permissions.yml: elderberry") + "\n").utf8), to: url)
            let changed7 = transcript.refresh()
            #expect(changed7)
            #expect(transcript.text.documentText.contains("permissions.yml: elderberry"))
        }
    }

    @Test
    func replacedTranscriptStartsOver() throws {
        try withTranscript([
            Self.userLine(uuid: "u-1", content: "an old conversation about apricots"),
            Self.userLine(uuid: "u-2", content: "and a second old prompt"),
        ]) { url in
            var transcript = AgentSessionSearchTranscript(path: url.path, agentKind: .claude)
            let changed8 = transcript.refresh()
            #expect(changed8)

            try (Self.userLine(uuid: "u-9", content: "resumed fresh") + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
            let changed9 = transcript.refresh()
            #expect(changed9)
            #expect(transcript.text.documentText.contains("resumed fresh"))
            #expect(!transcript.text.documentText.contains("apricots"))
        }
    }

    @Test
    func boundedQueueDropsOldestButKeepsTheNewestEntry() {
        var queue = BoundedTextQueue(byteLimit: 10)
        queue.append("aaaa")
        queue.append("bbbb")
        queue.append("cccc")
        #expect(queue.newestFirst == ["cccc", "bbbb"])

        queue.append(String(repeating: "z", count: 50))
        #expect(queue.newestFirst == [String(repeating: "z", count: 50)])
    }

    @Test
    func firstPromptSurvivesPromptOverflow() {
        var text = AgentSessionSearchText()
        let parser = ClaudeTranscriptParser()
        var lines = [Self.userLine(uuid: "u-0", content: "the opening ask")]
        for index in 1...40 {
            lines.append(Self.userLine(uuid: "u-\(index)", content: String(repeating: "x", count: 5_000) + " \(index)"))
        }
        text.append(parser.parse(lines: lines, startingSeq: 0, state: ChatTranscriptParseState()))
        let document = text.documentText
        #expect(document.hasPrefix("the opening ask\n"))
        #expect(document.utf8.count < AgentSessionSearchText.promptByteLimit + 10_000)
        #expect(document.contains(" 40"))
    }

    @Test
    func lineSplitterDropsAPartialFirstLineAndOversizedLines() {
        let oversized = String(repeating: "o", count: AgentSessionSearchTranscript.maxParsedLineBytes + 1)
        let buffer = Data("tail of a cut line\nkept one\n\(oversized)\nkept two\npartial".utf8)
        let split = AgentSessionSearchTranscript.completeLines(in: buffer, dropsFirstLine: true)
        #expect(split.lines == ["kept one", "kept two"])
        #expect(split.remainder == Data("partial".utf8))
    }

    @Test
    func revisionChangesOnlyWhenTheTextChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        try (Self.userLine(uuid: "u-1", content: "first ask about quinces") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        let source = AgentSessionSearchSource(
            sessionID: "s-1",
            agentKind: .claude,
            transcriptPath: url.path,
            title: "Quinces",
            workingDirectory: nil
        )
        let transcripts = AgentSessionSearchTranscripts()

        let firstRevision = await transcripts.refreshedRevision(for: source)
        let first = try #require(firstRevision)
        let unchanged = await transcripts.refreshedRevision(for: source)
        #expect(unchanged == first)

        try Self.append(Data((Self.userLine(uuid: "u-2", content: "and medlars") + "\n").utf8), to: url)
        let grownRevision = await transcripts.refreshedRevision(for: source)
        let grown = try #require(grownRevision)
        #expect(grown != first)
        let text = await transcripts.text(forSessionID: "s-1")
        #expect(text?.contains("and medlars") == true)

        await transcripts.retainOnly(sessionIDs: [])
        let pruned = await transcripts.text(forSessionID: "s-1")
        #expect(pruned == nil)
    }

    // MARK: - Fixtures

    private func withTranscript(_ lines: [String], _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        try lines.map { $0 + "\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
        try body(url)
    }

    private static func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    static func userLine(uuid: String, content: String) -> String {
        json([
            "parentUuid": NSNull(), "isSidechain": false, "type": "user",
            "message": ["role": "user", "content": content],
            "uuid": uuid, "timestamp": "2026-09-30T05:07:51.103Z", "sessionId": "s-1",
        ])
    }

    static func assistantLine(uuid: String, blocks: [[String: Any]]) -> String {
        json([
            "parentUuid": "u-1", "isSidechain": false, "type": "assistant",
            "message": ["role": "assistant", "content": blocks],
            "uuid": uuid, "timestamp": "2026-09-30T05:08:20.730Z", "sessionId": "s-1",
        ])
    }

    static func toolResultLine(toolUseID: String, content: String) -> String {
        json([
            "parentUuid": "a-1", "isSidechain": false, "type": "user",
            "message": ["role": "user", "content": [["tool_use_id": toolUseID, "type": "tool_result", "content": content]]],
            "uuid": "r-1", "timestamp": "2026-09-30T05:08:23.317Z", "sessionId": "s-1",
        ])
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
