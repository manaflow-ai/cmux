import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct CodexRestoreOwnerGenerationTests {
    @Test("A current hook binds an argv-hiding wrapper to its conversation")
    func wrapperOwnsHookSession() throws {
        let identity = try #require(AgentPIDProcessIdentity(pid: getpid()))
        let (record, snapshot, workspaceID, surfaceID) = try fixture(identity: identity)
        let observation = LiveAgentSessionOwnerObservation.validatingHookRecord(
            snapshot: snapshot, record: record, workspaceID: workspaceID, surfaceID: surfaceID,
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: { _ in identity },
            validator: CachedAgentProcessIdentityValidator()
        )
        let owner = try #require(observation?.owner)
        #expect(owner.sessionID == snapshot.sessionId)
        let index = LiveAgentSessionOwnerIndex(observations: [try #require(observation)])
        #expect(index.owner(
            kind: "codex", sessionID: snapshot.sessionId,
            processArgumentsProvider: { _ in nil }, processIdentityProvider: { _ in identity }
        )?.processIdentity == identity)
    }

    @Test("A reboot or PID reuse invalidates the old hook owner", arguments: [false, true])
    func previousGenerationCannotOwnRestore(reused: Bool) throws {
        let identity = try #require(AgentPIDProcessIdentity(pid: getpid()))
        let (record, snapshot, workspaceID, surfaceID) = try fixture(identity: identity)
        let current = reused ? AgentPIDProcessIdentity(
            pid: identity.pid, startSeconds: identity.startSeconds + 1,
            startMicroseconds: identity.startMicroseconds
        ) : nil
        #expect(LiveAgentSessionOwnerObservation.validatingHookRecord(
            snapshot: snapshot, record: record, workspaceID: workspaceID, surfaceID: surfaceID,
            processArgumentsProvider: { _ in nil }, processIdentityProvider: { _ in current },
            validator: CachedAgentProcessIdentityValidator()
        ) == nil)
    }

    private func fixture(identity: AgentPIDProcessIdentity) throws -> (
        RestorableAgentHookSessionRecord, SessionRestorableAgentSnapshot, UUID, UUID
    ) {
        let session = UUID().uuidString.lowercased()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let record = try JSONDecoder().decode(RestorableAgentHookSessionRecord.self, from:
            JSONSerialization.data(withJSONObject: [
                "sessionId": session, "workspaceId": workspaceID.uuidString,
                "surfaceId": surfaceID.uuidString, "pid": Int(identity.pid),
                "pidStartSeconds": identity.startSeconds,
                "pidStartMicroseconds": identity.startMicroseconds, "updatedAt": 1_800_000_000
            ])
        )
        return (record, SessionRestorableAgentSnapshot(
            kind: .codex, sessionId: session, workingDirectory: "/tmp"
        ), workspaceID, surfaceID)
    }
}
