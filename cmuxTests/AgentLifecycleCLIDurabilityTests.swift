import Foundation
import Testing

@Suite(.serialized)
struct AgentLifecycleCLIDurabilityTests {
    @Test func deferredSettlementReplayClaimsAreExclusiveAndLeaseBound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-deferred-settlement-claim-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedTestClock(
            date: Date(timeIntervalSince1970: 1_000)
        )
        let store = ClaudeHookSessionStore(
            processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": root
                    .appendingPathComponent("state.json")
                    .path,
            ],
            clock: { clock.now() }
        )
        let generation = AgentPIDProcessIdentity(
            pid: 7_777,
            startSeconds: 100,
            startMicroseconds: 200
        )
        let sessionID = "claim-session"
        let turnID = "claim-turn"
        let workID = "claim-work"

        _ = try store.recordStructuredBackgroundWorkEvent(
            sessionId: sessionID,
            eventName: "SubagentStart",
            workId: workID,
            turnId: turnID,
            processGeneration: generation,
            workspaceId: "workspace",
            surfaceId: "surface",
            cwd: "/tmp"
        )
        #expect(
            try store.deferTurnSettlementIfStructuredWorkActive(
                sessionId: sessionID,
                workspaceId: "workspace",
                surfaceId: "surface",
                cwd: "/tmp",
                turnId: turnID,
                processGeneration: generation,
                transcriptPath: nil,
                lastAssistantMessage: nil
            ) == 1
        )
        let firstClaim = try #require(
            try store.recordStructuredBackgroundWorkEvent(
                sessionId: sessionID,
                eventName: "SubagentStop",
                workId: workID,
                turnId: turnID,
                processGeneration: generation,
                workspaceId: "workspace",
                surfaceId: "surface",
                cwd: "/tmp"
            ).deferredSettlement
        )
        #expect(firstClaim.replayClaimID != nil)
        #expect(
            try store.recordStructuredBackgroundWorkEvent(
                sessionId: sessionID,
                eventName: "SubagentStop",
                workId: workID,
                turnId: turnID,
                processGeneration: generation,
                workspaceId: "workspace",
                surfaceId: "surface",
                cwd: "/tmp"
            ).deferredSettlement == nil
        )

        clock.advance(by: 11)
        let replacementClaim = try #require(
            try store.recordStructuredBackgroundWorkEvent(
                sessionId: sessionID,
                eventName: "SubagentStop",
                workId: workID,
                turnId: turnID,
                processGeneration: generation,
                workspaceId: "workspace",
                surfaceId: "surface",
                cwd: "/tmp"
            ).deferredSettlement
        )
        #expect(replacementClaim.id == firstClaim.id)
        #expect(replacementClaim.replayClaimID != firstClaim.replayClaimID)

        try store.releaseDeferredTurnSettlementReplayClaim(
            sessionId: sessionID,
            settlement: firstClaim
        )
        #expect(
            try store.recordStructuredBackgroundWorkEvent(
                sessionId: sessionID,
                eventName: "SubagentStop",
                workId: workID,
                turnId: turnID,
                processGeneration: generation,
                workspaceId: "workspace",
                surfaceId: "surface",
                cwd: "/tmp"
            ).deferredSettlement == nil,
            "An expired owner must not release its replacement's exact claim."
        )
    }

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

    private final class LockedTestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(date: Date) {
            self.date = date
        }

        func now() -> Date {
            lock.withLock { date }
        }

        func advance(by seconds: TimeInterval) {
            lock.withLock {
                date = date.addingTimeInterval(seconds)
            }
        }
    }
}
