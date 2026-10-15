import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Claude session start with a transcript path fills the record's own title
/// and last prompt from the transcript tail, off the main actor, and the
/// sidebar change event names the session's pane.
struct AgentChatTranscriptServiceTailReadTests {
    @MainActor
    @Test func sessionStartReadsTheTranscriptTailAndPostsTheSidebarEvent() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let transcript = home.appendingPathComponent("session.jsonl")
        try [
            #"{"type":"user","sessionId":"s-1","message":{"role":"user","content":"do it"}}"#,
            #"{"type":"last-prompt","lastPrompt":"do it","leafUuid":"l-1","sessionId":"s-1"}"#,
            #"{"type":"ai-title","aiTitle":"Hello","sessionId":"s-1"}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        final class Seen: @unchecked Sendable {
            var panelIds: Set<UUID> = []
        }
        let seen = Seen()
        let observer = NotificationCenter.default.addObserver(
            forName: AgentSessionSidebarDidChangeEvent.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            if let event = AgentSessionSidebarDidChangeEvent(notification) {
                seen.panelIds.formUnion(event.panelIds)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        let sessionID = "88888888-8888-8888-8888-888888888888"
        let panelId = UUID()
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: UUID().uuidString,
            surfaceId: panelId.uuidString,
            transcriptPath: transcript.path,
            cwd: home.path,
            receivedAt: Date()
        ))

        var record = service.sessionRecord(sessionID: sessionID)
        for _ in 0..<40 where record?.aiTitle == nil {
            try await Task.sleep(for: .milliseconds(50))
            record = service.sessionRecord(sessionID: sessionID)
        }
        #expect(record?.aiTitle == "Hello")
        #expect(record?.lastPrompt == "do it")
        #expect(record?.lastPromptAt == nil)
        #expect(seen.panelIds.contains(panelId))
        #expect(service.lastTypedLiveSessions().isEmpty)
        #expect(service.liveSessionRecord(surfaceID: panelId.uuidString)?.sessionID == sessionID)
    }
}
