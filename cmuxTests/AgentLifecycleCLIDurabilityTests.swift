import Foundation
import Testing

@Suite(.serialized)
struct AgentLifecycleCLIDurabilityTests {
    @Test func deferredSettlementReplayClaimsAreExclusiveAndLeaseBound() throws {
        let settlement = AgentDeferredTurnSettlement(
            id: UUID(),
            turnId: "claim-turn",
            workspaceId: "workspace",
            surfaceId: "surface",
            transcriptPath: nil,
            lastAssistantMessage: nil
        )
        let firstClaimID = UUID()
        let firstClaim = try #require(
            settlement.claimingReplay(
                at: 1_000,
                leaseDuration: 10,
                claimID: firstClaimID
            )
        )
        #expect(firstClaim.replayClaimID == firstClaimID)
        #expect(
            firstClaim.claimingReplay(
                at: 1_009,
                leaseDuration: 10,
                claimID: UUID()
            ) == nil
        )

        let replacementClaimID = UUID()
        let replacementClaim = try #require(
            firstClaim.claimingReplay(
                at: 1_011,
                leaseDuration: 10,
                claimID: replacementClaimID
            )
        )
        #expect(replacementClaim.id == firstClaim.id)
        #expect(replacementClaim.replayClaimID == replacementClaimID)
        #expect(
            replacementClaim.releasingReplayClaim(
                matching: firstClaim
            ) == nil,
            "An expired owner must not release its replacement's exact claim."
        )
        let released = try #require(
            replacementClaim.releasingReplayClaim(
                matching: replacementClaim
            )
        )
        #expect(released.replayClaimID == nil)
        #expect(released.replayClaimedAt == nil)
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
        let startTime = ISO8601DateFormatter().string(from: Date())
        var header = try JSONSerialization.data(
            withJSONObject: [
                "event": "debug-session-start",
                "pid": Int(processIdentity.pid),
                "startTime": startTime,
            ]
        )
        header.append(0x0A)
        var record = try JSONSerialization.data(
            withJSONObject: [
                "msg": "Shell permissions: requesting shell approval",
                "toolCallId": toolCallID,
            ]
        )
        header.append(record)
        record = header
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
}
