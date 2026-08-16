import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct VaultSocketPayloadTests {
    private var entry: SessionEntry {
        SessionEntry(
            id: "claude:/tmp/s.jsonl",
            agent: .claude,
            sessionId: "session-1",
            title: "Fix the bug",
            cwd: "/Users/dev/cmux",
            gitBranch: "main",
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_755_000_000),
            fileURL: URL(fileURLWithPath: "/tmp/s.jsonl"),
            specifics: .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil),
            created: Date(timeIntervalSince1970: 1_754_000_000),
            messageCount: 7
        )
    }

    @Test
    func sessionPayloadCarriesIdentityStatusAndResumeCommand() {
        let now = Date(timeIntervalSince1970: 1_755_000_060)
        let payload = TerminalController.vaultSessionPayload(
            entry,
            liveKeys: [VaultLiveSessionKeys.key(for: entry)],
            now: now
        )
        #expect(payload["agent"] as? String == "claude")
        #expect(payload["session_id"] as? String == "session-1")
        #expect(payload["status"] as? String == "live")
        #expect(payload["title"] as? String == "Fix the bug")
        #expect(payload["cwd"] as? String == "/Users/dev/cmux")
        #expect(payload["git_branch"] as? String == "main")
        #expect(payload["message_count"] as? Int == 7)
        #expect((payload["resume_command"] as? String)?.contains("session-1") == true)
        // The whole payload must be JSON-encodable for the wire.
        #expect(JSONSerialization.isValidJSONObject(payload))
    }

    @Test
    func sessionPayloadWithoutProcessIsEnded() {
        let payload = TerminalController.vaultSessionPayload(
            entry,
            liveKeys: [],
            now: Date(timeIntervalSince1970: 1_755_000_060)
        )
        #expect(payload["status"] as? String == "exited")
    }

    @Test
    func checkpointPayloadOmitsAbsentFields() {
        let bare = VaultSessionCheckpoint(
            id: "turn:uuid:u1", source: .turn, timestamp: nil, name: nil,
            turnIndex: 1, anchor: "uuid:u1", gitSHA: nil, promptSnippet: "hello"
        )
        let payload = TerminalController.vaultCheckpointPayload(bare)
        #expect(payload["id"] as? String == "turn:uuid:u1")
        #expect(payload["source"] as? String == "turn")
        #expect(payload["turn"] as? Int == 1)
        #expect(payload["anchor"] as? String == "uuid:u1")
        #expect(payload["prompt"] as? String == "hello")
        #expect(payload["name"] == nil)
        #expect(payload["git_sha"] == nil)
        #expect(JSONSerialization.isValidJSONObject(payload))

        let manual = VaultSessionCheckpoint(
            id: "manual:m1", source: .manual, timestamp: Date(timeIntervalSince1970: 0),
            name: "before refactor", turnIndex: 3, anchor: nil,
            gitSHA: "0123456789abcdef0123456789abcdef01234567", promptSnippet: nil
        )
        let manualPayload = TerminalController.vaultCheckpointPayload(manual)
        #expect(manualPayload["name"] as? String == "before refactor")
        #expect(manualPayload["git_sha"] as? String == "0123456789abcdef0123456789abcdef01234567")
        #expect(manualPayload["timestamp"] as? String != nil)
    }
}
