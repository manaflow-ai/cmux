import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct VaultCheckpointForkTests {
    private let parentSessionID = "aaaaaaaa-1111-2222-3333-444444444444"
    private let newSessionID = "bbbbbbbb-5555-6666-7777-888888888888"

    private func line(
        uuid: String,
        type: String,
        text: String,
        sessionID: String? = nil
    ) -> String {
        let session = sessionID ?? parentSessionID
        if type == "user" {
            return #"{"sessionId":"\#(session)","uuid":"\#(uuid)","type":"user","timestamp":"2026-08-14T10:00:00Z","message":{"role":"user","content":"\#(text)"}}"#
        }
        return #"{"sessionId":"\#(session)","uuid":"\#(uuid)","type":"assistant","timestamp":"2026-08-14T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func writeParent(_ lines: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fork-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(parentSessionID + ".jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func readLines(_ url: URL) throws -> [[String: Any]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func turnCheckpoint(anchorUUID: String?, turnIndex: Int) -> VaultSessionCheckpoint {
        VaultSessionCheckpoint(
            id: "turn:test",
            source: .turn,
            timestamp: nil,
            name: nil,
            turnIndex: turnIndex,
            anchorLineUUID: anchorUUID,
            gitSHA: nil,
            promptSnippet: nil
        )
    }

    @Test
    func turnForkCopiesStrictlyBeforeAnchorAndRewritesEverySessionID() throws {
        let parent = try writeParent([
            line(uuid: "u1", type: "user", text: "first prompt"),
            line(uuid: "a1", type: "assistant", text: "reply one"),
            line(uuid: "u2", type: "user", text: "second prompt"),
            line(uuid: "a2", type: "assistant", text: "reply two"),
        ])
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }
        let parentBytes = try Data(contentsOf: parent)

        let forked = try VaultCheckpointForker.forkClaudeTranscript(
            parentFileURL: parent,
            checkpoint: turnCheckpoint(anchorUUID: "u2", turnIndex: 2),
            newSessionID: newSessionID
        )

        let rows = try readLines(forked)
        // Strictly before the second user prompt: u1 + a1 only.
        #expect(rows.count == 2)
        #expect(rows.map { $0["uuid"] as? String } == ["u1", "a1"])
        // #10156 class: every line carries the NEW session id; never the parent's.
        for row in rows {
            #expect(row["sessionId"] as? String == newSessionID)
        }
        #expect(forked.lastPathComponent == newSessionID + ".jsonl")
        // Parent untouched, byte-for-byte.
        #expect(try Data(contentsOf: parent) == parentBytes)
    }

    @Test
    func turnForkFallsBackToTurnIndexWhenAnchorUUIDAbsent() throws {
        let parent = try writeParent([
            line(uuid: "u1", type: "user", text: "first"),
            line(uuid: "a1", type: "assistant", text: "one"),
            line(uuid: "u2", type: "user", text: "second"),
        ])
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }

        let forked = try VaultCheckpointForker.forkClaudeTranscript(
            parentFileURL: parent,
            checkpoint: turnCheckpoint(anchorUUID: nil, turnIndex: 2),
            newSessionID: newSessionID
        )
        let rows = try readLines(forked)
        #expect(rows.map { $0["uuid"] as? String } == ["u1", "a1"])
    }

    @Test
    func manualForkCopiesThroughAnchorInclusive() throws {
        let parent = try writeParent([
            line(uuid: "u1", type: "user", text: "first"),
            line(uuid: "a1", type: "assistant", text: "one"),
            line(uuid: "u2", type: "user", text: "second"),
        ])
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }

        let manual = VaultSessionCheckpoint(
            id: "manual:test",
            source: .manual,
            timestamp: nil,
            name: "before refactor",
            turnIndex: 1,
            anchorLineUUID: "a1",
            gitSHA: nil,
            promptSnippet: nil
        )
        let forked = try VaultCheckpointForker.forkClaudeTranscript(
            parentFileURL: parent,
            checkpoint: manual,
            newSessionID: newSessionID
        )
        let rows = try readLines(forked)
        #expect(rows.map { $0["uuid"] as? String } == ["u1", "a1"])
    }

    @Test
    func multibyteContentSurvivesRewrite() throws {
        let parent = try writeParent([
            line(uuid: "u1", type: "user", text: "日本語のプロンプト🚀"),
            line(uuid: "u2", type: "user", text: "next"),
        ])
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }

        let forked = try VaultCheckpointForker.forkClaudeTranscript(
            parentFileURL: parent,
            checkpoint: turnCheckpoint(anchorUUID: "u2", turnIndex: 2),
            newSessionID: newSessionID
        )
        let rows = try readLines(forked)
        let message = rows[0]["message"] as? [String: Any]
        #expect(message?["content"] as? String == "日本語のプロンプト🚀")
        #expect(rows[0]["sessionId"] as? String == newSessionID)
    }

    @Test
    func nestedSessionIdStringsInContentAreNotTouched() throws {
        let embedded = #"{"sessionId":"\#(parentSessionID)","uuid":"u1","type":"user","message":{"role":"user","content":"the parent id is \#(parentSessionID)"}}"#
        let parent = try writeParent([
            embedded,
            line(uuid: "u2", type: "user", text: "next"),
        ])
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }

        let forked = try VaultCheckpointForker.forkClaudeTranscript(
            parentFileURL: parent,
            checkpoint: turnCheckpoint(anchorUUID: "u2", turnIndex: 2),
            newSessionID: newSessionID
        )
        let rows = try readLines(forked)
        #expect(rows[0]["sessionId"] as? String == newSessionID)
        let message = rows[0]["message"] as? [String: Any]
        // Content mentioning the parent id stays intact — only the top-level
        // field is identity.
        #expect((message?["content"] as? String)?.contains(parentSessionID) == true)
    }

    @Test
    func missingTurnAnchorThrowsInsteadOfForkingWholeTranscript() throws {
        let parent = try writeParent([
            line(uuid: "u1", type: "user", text: "only prompt"),
        ])
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }

        #expect(throws: VaultCheckpointForkError.anchorNotFound) {
            try VaultCheckpointForker.forkClaudeTranscript(
                parentFileURL: parent,
                checkpoint: turnCheckpoint(anchorUUID: "missing-uuid", turnIndex: 9),
                newSessionID: newSessionID
            )
        }
        // Failed forks must not leave a partial file behind.
        let leftover = parent.deletingLastPathComponent()
            .appendingPathComponent(newSessionID + ".jsonl")
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test
    func forkAtFirstTurnIsRefusedAsEmpty() throws {
        let parent = try writeParent([
            line(uuid: "u1", type: "user", text: "first"),
            line(uuid: "a1", type: "assistant", text: "one"),
        ])
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }

        #expect(throws: VaultCheckpointForkError.emptyFork) {
            try VaultCheckpointForker.forkClaudeTranscript(
                parentFileURL: parent,
                checkpoint: turnCheckpoint(anchorUUID: "u1", turnIndex: 1),
                newSessionID: newSessionID
            )
        }
    }

    @Test
    func byteCapAborts() throws {
        let parent = try writeParent([
            line(uuid: "u1", type: "user", text: String(repeating: "x", count: 4096)),
            line(uuid: "u2", type: "user", text: "next"),
        ])
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }

        #expect(throws: VaultCheckpointForkError.byteCapExceeded) {
            try VaultCheckpointForker.forkClaudeTranscript(
                parentFileURL: parent,
                checkpoint: turnCheckpoint(anchorUUID: "u2", turnIndex: 2),
                newSessionID: newSessionID,
                maxBytes: 1024
            )
        }
    }

    @Test
    func forkedEntryCarriesNewIdentityAndParentCwd() {
        let parent = SessionEntry(
            id: "claude:/tmp/parent.jsonl",
            agent: .claude,
            sessionId: parentSessionID,
            title: "Parent session",
            cwd: "/Users/dev/projects/cmux",
            gitBranch: "main",
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1000),
            fileURL: URL(fileURLWithPath: "/tmp/parent.jsonl"),
            specifics: .claude(model: "opus", permissionMode: nil, configDirectoryForResume: "/Users/dev/.claude")
        )
        let forkedURL = URL(fileURLWithPath: "/tmp/\(newSessionID).jsonl")
        let forked = parent.forkedClaudeEntry(
            newSessionID: newSessionID,
            fileURL: forkedURL,
            now: Date(timeIntervalSince1970: 2000)
        )
        #expect(forked.sessionId == newSessionID)
        #expect(forked.sessionId != parent.sessionId)
        // #5941: forks stay in the parent's cwd.
        #expect(forked.cwd == parent.cwd)
        #expect(forked.specifics == parent.specifics)
        // The resume command built for the forked entry uses the NEW id and
        // never the parent's (#10156 class).
        let resume = forked.copyResumeCommand
        #expect(resume?.contains(newSessionID) == true)
        #expect(resume?.contains(parentSessionID) == false)
    }
}
