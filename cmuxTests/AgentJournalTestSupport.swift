import Foundation

/// Shared parsing for `agent_journal_append <json>` lines captured by the CLI
/// hook mock socket servers: the structured replacement for the old
/// `set_agent_lifecycle` prefix assertions.
struct AgentJournalAppendCapture {
    /// The decoded draft object of one captured append line.
    let draft: [String: Any]

    var kind: String? { draft["kind"] as? String }
    var agentKey: String? { draft["agent_key"] as? String }
    var sessionId: String? { draft["session_id"] as? String }
    var workspaceId: String? { draft["workspace_id"] as? String }
    var surfaceId: String? { draft["surface_id"] as? String }
    var unattributedReason: String? { draft["unattributed_reason"] as? String }
    var isSubagent: Bool { draft["is_subagent"] as? Bool ?? false }
    var pendingWork: Bool { draft["pending_work"] as? Bool ?? false }

    static func captures(in commands: [String]) -> [AgentJournalAppendCapture] {
        commands.compactMap { line in
            guard line.hasPrefix("agent_journal_append ") else { return nil }
            let payload = String(line.dropFirst("agent_journal_append ".count))
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return AgentJournalAppendCapture(draft: object)
        }
    }

    static func first(
        in commands: [String],
        kind: String,
        agentKey: String? = nil,
        sessionId: String? = nil
    ) -> AgentJournalAppendCapture? {
        captures(in: commands).first { capture in
            capture.kind == kind
                && (agentKey == nil || capture.agentKey == agentKey)
                && (sessionId == nil || capture.sessionId == sessionId)
        }
    }

    static func contains(
        _ commands: [String],
        kind: String,
        agentKey: String? = nil,
        sessionId: String? = nil
    ) -> Bool {
        first(in: commands, kind: kind, agentKey: agentKey, sessionId: sessionId) != nil
    }
}
