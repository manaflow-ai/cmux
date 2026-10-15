import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The registry's contribution to the sidebar session rows: last prompt
/// capture, transcript tail adoption, and last-typed ordering.
struct AgentChatSessionRegistryPromptTrackingTests {
    private let t1 = Date(timeIntervalSince1970: 1_000)
    private let t2 = Date(timeIntervalSince1970: 2_000)

    private func promptEvent(
        sessionID: String,
        surfaceID: String = UUID().uuidString,
        toolInputJSON: String?,
        context: WorkstreamContext? = nil,
        at date: Date
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: UUID().uuidString,
            surfaceId: surfaceID,
            transcriptPath: nil,
            cwd: "/tmp/project",
            toolInputJSON: toolInputJSON,
            context: context,
            receivedAt: date
        )
    }

    @MainActor
    @Test func promptSubmitRecordsThePromptAndItsTime() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let record = registry.noteHookEvent(promptEvent(
            sessionID: sessionID,
            toolInputJSON: #"{"prompt":"fix the login bug"}"#,
            at: t1
        ))
        #expect(record.lastPrompt == "fix the login bug")
        #expect(record.lastPromptAt == t1)
        #expect(registry.record(sessionID: sessionID)?.lastPrompt == "fix the login bug")
    }

    @MainActor
    @Test func promptFallsBackToContextLastUserMessage() {
        let registry = AgentChatSessionRegistry()
        let record = registry.noteHookEvent(promptEvent(
            sessionID: "22222222-2222-2222-2222-222222222222",
            toolInputJSON: nil,
            context: WorkstreamContext(lastUserMessage: "from ctx"),
            at: t1
        ))
        #expect(record.lastPrompt == "from ctx")
    }

    @MainActor
    @Test func toolEventsLeaveThePromptAlone() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "33333333-3333-3333-3333-333333333333"
        let surfaceID = UUID().uuidString
        _ = registry.noteHookEvent(promptEvent(
            sessionID: sessionID,
            surfaceID: surfaceID,
            toolInputJSON: #"{"prompt":"first"}"#,
            at: t1
        ))
        let after = registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .preToolUse,
            source: "claude",
            surfaceId: surfaceID,
            toolName: "Bash",
            toolInputJSON: #"{"command":"ls"}"#,
            receivedAt: t2
        ))
        #expect(after.lastPrompt == "first")
        #expect(after.lastPromptAt == t1)
        #expect(after.lastActivityAt == t2)
    }

    @MainActor
    @Test func transcriptTailFillsTitleButNeverOverridesAHookPrompt() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "44444444-4444-4444-4444-444444444444"
        _ = registry.noteHookEvent(promptEvent(
            sessionID: sessionID,
            toolInputJSON: #"{"prompt":"hook prompt"}"#,
            at: t1
        ))
        registry.applyTranscriptTail(
            sessionID: sessionID,
            tail: ClaudeTranscriptTailReader.Tail(aiTitle: "Login bug fix", lastPrompt: "tail prompt")
        )
        let record = registry.record(sessionID: sessionID)
        #expect(record?.aiTitle == "Login bug fix")
        #expect(record?.lastPrompt == "hook prompt")
        #expect(record?.lastPromptAt == t1)
    }

    @MainActor
    @Test func transcriptTailFillsAMissingPromptWithoutATimestamp() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "55555555-5555-5555-5555-555555555555"
        _ = registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            surfaceId: UUID().uuidString,
            receivedAt: t1
        ))
        registry.applyTranscriptTail(
            sessionID: sessionID,
            tail: ClaudeTranscriptTailReader.Tail(aiTitle: nil, lastPrompt: "tail prompt")
        )
        let record = registry.record(sessionID: sessionID)
        #expect(record?.lastPrompt == "tail prompt")
        #expect(record?.lastPromptAt == nil)
    }

    @MainActor
    @Test func applyingTheSameTailTwiceDoesNotBumpTheVersion() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "66666666-6666-6666-6666-666666666666"
        _ = registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            surfaceId: UUID().uuidString,
            receivedAt: t1
        ))
        let tail = ClaudeTranscriptTailReader.Tail(aiTitle: "Title", lastPrompt: "prompt")
        registry.applyTranscriptTail(sessionID: sessionID, tail: tail)
        let version = registry.record(sessionID: sessionID)?.version
        registry.applyTranscriptTail(sessionID: sessionID, tail: tail)
        #expect(registry.record(sessionID: sessionID)?.version == version)
    }

    @MainActor
    @Test func lastTypedOrdersByPromptTimeAndSkipsEndedAndUnboundSessions() {
        let registry = AgentChatSessionRegistry()
        let older = "77777777-7777-7777-7777-777777777771"
        let newer = "77777777-7777-7777-7777-777777777772"
        let ended = "77777777-7777-7777-7777-777777777773"
        let unbound = "77777777-7777-7777-7777-777777777774"
        _ = registry.noteHookEvent(promptEvent(sessionID: older, toolInputJSON: #"{"prompt":"a"}"#, at: t1))
        _ = registry.noteHookEvent(promptEvent(sessionID: newer, toolInputJSON: #"{"prompt":"b"}"#, at: t2))
        let endedSurface = UUID().uuidString
        _ = registry.noteHookEvent(promptEvent(sessionID: ended, surfaceID: endedSurface, toolInputJSON: #"{"prompt":"c"}"#, at: t2))
        _ = registry.noteHookEvent(WorkstreamEvent(
            sessionId: ended,
            hookEventName: .sessionEnd,
            source: "claude",
            surfaceId: endedSurface,
            receivedAt: t2
        ))
        _ = registry.noteHookEvent(WorkstreamEvent(
            sessionId: unbound,
            hookEventName: .userPromptSubmit,
            source: "claude",
            toolInputJSON: #"{"prompt":"d"}"#,
            receivedAt: t2
        ))

        let ordered = registry.lastTypedLiveSessions().map(\.sessionID)
        #expect(ordered == [newer, older])
    }
}
