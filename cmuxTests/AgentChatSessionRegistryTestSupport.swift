#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif
import CmuxAgentChat
import Foundation

@MainActor
extension AgentChatSessionRegistry {
    /// Test-only: synthesize a record and fire the real notification path so
    /// observers (transcript service / sidebar bridge) receive it. Mirrors the
    /// create path (`update` is mutate-existing-only, so it no-ops on a fresh id).
    /// Intentionally omits `stampVersion` (matching the former in-source seam);
    /// the observer/bridge tests do not assert on record version.
    func emitForTest(sessionID: String, kind: ChatAgentKind, workspaceID: String?,
                     state: ChatAgentState, pid: Int?) {
        let previous = records[sessionID]
        let record = AgentChatSessionRecord(
            sessionID: sessionID, agentKind: kind, workspaceID: workspaceID,
            surfaceID: nil, workingDirectory: nil, transcriptPath: nil,
            state: state, lastActivityAt: Date(), title: nil, pid: pid)
        records[sessionID] = record
        notifyRecordChange(record, previous)
    }
}
