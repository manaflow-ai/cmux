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

    @Test func cursorApprovalObserverLeasesBoundEachProcessGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cursor-observer-leases-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstGeneration = try #require(
            AgentPIDProcessIdentity(
                agentTurnPID: Int(ProcessInfo.processInfo.processIdentifier)
            )
        )
        let secondGeneration = AgentPIDProcessIdentity(
            pid: firstGeneration.pid,
            startSeconds: firstGeneration.startSeconds + 1,
            startMicroseconds: firstGeneration.startMicroseconds
        )
        var leases: [CursorNativeApprovalObserverLease] = []
        defer { leases.forEach { $0.release() } }

        for index in 0 ..< CursorNativeApprovalObserverLease
            .maximumConcurrentObserversPerProcess {
            leases.append(
                try #require(
                    CursorNativeApprovalObserverLease.claim(
                        processIdentity: firstGeneration,
                        observationID: "first-generation-\(index)",
                        rootDirectory: root
                    )
                )
            )
        }

        #expect(
            CursorNativeApprovalObserverLease.claim(
                processIdentity: firstGeneration,
                observationID: "over-capacity",
                rootDirectory: root
            ) == nil
        )
        let otherGenerationLease = try #require(
            CursorNativeApprovalObserverLease.claim(
                processIdentity: secondGeneration,
                observationID: "second-generation",
                rootDirectory: root
            )
        )
        otherGenerationLease.release()

        let cancelledLease = leases.removeLast()
        CursorNativeApprovalObserverLease.cancel(
            processIdentity: firstGeneration,
            observationID: cancelledLease.observationID,
            rootDirectory: root
        )
        let replacementLease = try #require(
            CursorNativeApprovalObserverLease.claim(
                processIdentity: firstGeneration,
                observationID: "replacement-observation",
                rootDirectory: root
            )
        )
        replacementLease.release()
    }

    @Test func terminalWorkTombstoneOverflowDefersDelayedSettlement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-terminal-work-overflow-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeHookSessionStore(
            processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": root
                    .appendingPathComponent("sessions.json")
                    .path,
            ]
        )
        let processIdentity = try #require(
            AgentPIDProcessIdentity(
                agentTurnPID: Int(ProcessInfo.processInfo.processIdentifier)
            )
        )
        let sessionID = "terminal-overflow-session"
        let turnID = "terminal-overflow-turn"
        let workspaceID = "33333333-3333-3333-3333-333333333333"
        let surfaceID = "44444444-4444-4444-4444-444444444444"
        var update = AgentStructuredBackgroundWorkUpdate(
            activeWorkCount: 0,
            deferredSettlement: nil
        )

        for index in 0 ... 64 {
            update = try store.recordStructuredBackgroundWorkEvent(
                sessionId: sessionID,
                eventName: "SubagentStop",
                workId: "completed-work-\(index)",
                turnId: turnID,
                processGeneration: processIdentity,
                workspaceId: workspaceID,
                surfaceId: surfaceID,
                cwd: root.path
            )
        }

        #expect(update.activeWorkCount == 1)
        #expect(
            try store.lookup(sessionId: sessionID)?
                .backgroundWorkOverflowTurnKeys?.contains(turnID) == true
        )
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
        let delayedStart = try store.recordStructuredBackgroundWorkEvent(
            sessionId: sessionID,
            eventName: "SubagentStart",
            workId: "completed-work-0",
            turnId: turnID,
            processGeneration: processIdentity,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: root.path
        )
        #expect(delayedStart.activeWorkCount > 0)
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
