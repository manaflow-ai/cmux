import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent chat registry approval waits", .serialized)
@MainActor
struct AgentChatSessionRegistryApprovalWaitTests {
    @Test(arguments: [
        WorkstreamEvent.HookEventName.preCompact,
        .postCompact,
        .subagentStart,
        .subagentStop,
    ])
    func lifecycleTelemetryClearsApprovalWaitNeedsInput(
        hookEventName: WorkstreamEvent.HookEventName
    ) {
        let registry = AgentChatSessionRegistry()
        let sessionID = "mobile-approval-wait"
        let waitAt = Date(timeIntervalSince1970: 1_000)
        let followUpAt = Date(timeIntervalSince1970: 1_001)

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .approvalWait,
            source: "codex",
            toolName: "shell",
            toolInputJSON: #"{"command":"touch /tmp/x"}"#,
            receivedAt: waitAt
        ))

        #expect(registry.record(sessionID: sessionID)?.state == .needsInput(since: waitAt))

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: hookEventName,
            source: "codex",
            receivedAt: followUpAt
        ))

        #expect(registry.record(sessionID: sessionID)?.state == .idle)
    }

    @Test func blockingFollowUpReplacesApprovalWaitNeedsInput() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "mobile-approval-to-permission"
        let waitAt = Date(timeIntervalSince1970: 2_000)
        let permissionAt = Date(timeIntervalSince1970: 2_001)

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .approvalWait,
            source: "codex",
            toolName: "shell",
            toolInputJSON: #"{"command":"touch /tmp/x"}"#,
            receivedAt: waitAt
        ))

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .permissionRequest,
            source: "codex",
            toolName: "shell",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: "permission-after-approval",
            receivedAt: permissionAt
        ))

        #expect(registry.record(sessionID: sessionID)?.state == .needsInput(since: permissionAt))
    }

    @Test func approvalWaitTelemetryDoesNotClearExistingBlockingNeedsInput() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "mobile-permission-before-approval"
        let permissionAt = Date(timeIntervalSince1970: 3_000)
        let waitAt = Date(timeIntervalSince1970: 3_001)
        let followUpAt = Date(timeIntervalSince1970: 3_002)

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .permissionRequest,
            source: "codex",
            toolName: "shell",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: "permission-before-approval",
            receivedAt: permissionAt
        ))

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .approvalWait,
            source: "codex",
            toolName: "shell",
            toolInputJSON: #"{"command":"touch /tmp/x"}"#,
            receivedAt: waitAt
        ))

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .preCompact,
            source: "codex",
            receivedAt: followUpAt
        ))

        #expect(registry.record(sessionID: sessionID)?.state == .needsInput(since: permissionAt))
    }
}
