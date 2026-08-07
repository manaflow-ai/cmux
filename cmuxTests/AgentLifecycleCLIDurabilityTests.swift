import Foundation
import Testing

@Suite(.serialized)
struct AgentLifecycleCLIDurabilityTests {
    @Test func cursorApprovalDiscoveryDoesNotMaterializeTheLogDirectory() throws {
        let fileManager = RefusingDirectoryMaterializationFileManager()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cursor-log-discovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let processIdentity = try #require(
            AgentPIDProcessIdentity(
                agentTurnPID: Int(ProcessInfo.processInfo.processIdentifier)
            )
        )
        let toolCallID = "cursor-bounded-discovery"
        let logURL = root.appendingPathComponent(
            "cursor-test-\(processIdentity.pid)-1.log",
            isDirectory: false
        )
        var record = try JSONSerialization.data(
            withJSONObject: [
                "msg": "Shell permissions: requesting shell approval",
                "toolCallId": toolCallID,
            ]
        )
        record.append(0x0A)
        try record.write(to: logURL)

        let outcome = CursorNativeApprovalFileObserver(
            logDirectory: root,
            processIdentity: processIdentity,
            expectedToolCallId: toolCallID,
            fileManager: fileManager
        ).waitForDecision()

        #expect(outcome == .approvalRequested)
    }

    @Test func drainedSettlementRemainsDurableUntilReplayAcknowledgement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-deferred-settlement-durability-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent(
            "codex-hook-sessions.json",
            isDirectory: false
        )
        let store = ClaudeHookSessionStore(
            processEnv: ["CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path]
        )
        let processIdentity = try #require(
            AgentPIDProcessIdentity(
                agentTurnPID: Int(ProcessInfo.processInfo.processIdentifier)
            )
        )
        let sessionID = "durable-settlement-session"
        let turnID = "durable-settlement-turn"
        let workID = "durable-settlement-work"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"

        let started = try store.recordStructuredBackgroundWorkEvent(
            sessionId: sessionID,
            eventName: "SubagentStart",
            workId: workID,
            turnId: turnID,
            processGeneration: processIdentity,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: root.path
        )
        #expect(started.activeWorkCount == 1)
        #expect(
            try store.deferTurnSettlementIfStructuredWorkActive(
                sessionId: sessionID,
                workspaceId: workspaceID,
                surfaceId: surfaceID,
                cwd: root.path,
                turnId: turnID,
                processGeneration: processIdentity,
                transcriptPath: nil,
                lastAssistantMessage: "done"
            ) == 1
        )

        let drained = try store.recordStructuredBackgroundWorkEvent(
            sessionId: sessionID,
            eventName: "SubagentStop",
            workId: workID,
            turnId: turnID,
            processGeneration: processIdentity,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: root.path
        )
        let settlement = try #require(drained.deferredSettlement)
        let persisted = try #require(
            store.lookup(sessionId: sessionID)?
                .deferredTurnSettlementsByTurn?[turnID]
        )

        #expect(drained.activeWorkCount == 0)
        #expect(persisted == settlement)
    }

    /// A stateless filesystem double that makes eager directory loading fail.
    private final class RefusingDirectoryMaterializationFileManager:
        FileManager,
        @unchecked Sendable
    {
        override func contentsOfDirectory(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: DirectoryEnumerationOptions
        ) throws -> [URL] {
            throw CocoaError(.fileReadTooLarge)
        }
    }
}
