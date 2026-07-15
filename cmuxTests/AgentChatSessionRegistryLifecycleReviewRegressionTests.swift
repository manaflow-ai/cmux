import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryLifecycleReviewRegressionTests {
    @MainActor
    @Test func relaunchOnlyPlaceholderCannotBecomeResumeSessionIdentity() {
        #expect(!AgentChatTranscriptService.isValidResumeSessionID(""))
        #expect(!AgentChatTranscriptService.isValidResumeSessionID("  \n"))
        #expect(AgentChatTranscriptService.isValidResumeSessionID("upstream-session-id"))
    }

    @MainActor
    @Test func endedSessionListabilityRetriesTransientMissingTranscriptAfterRetryWindow() throws {
        let home = try temporaryHomeDirectory()
        var now = Date(timeIntervalSince1970: 260)
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            now: { now }
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")

        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionEnd,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: transcriptURL.path,
            cwd: "/Users/example/project",
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 260)
        ))
        let initiallyMissingRecord = try #require(service.sessionRecord(sessionID: sessionID))
        #expect(!service.shouldListEndedSession(initiallyMissingRecord))

        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        let resolvedRecord = try #require(service.sessionRecord(sessionID: sessionID))
        now = Date(timeIntervalSince1970: 264)
        #expect(!service.shouldListEndedSession(resolvedRecord))
        now = Date(timeIntervalSince1970: 266)
        #expect(service.shouldListEndedSession(resolvedRecord))
    }

    @Test func endedListabilityCacheRefreshesExpiredMissingTranscript() throws {
        let home = try temporaryHomeDirectory()
        let resolver = AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        let record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: transcriptURL.path,
            state: .ended,
            endedAt: Date(timeIntervalSince1970: 10),
            lastActivityAt: Date(timeIntervalSince1970: 10),
            title: nil,
            pid: nil,
            hookStoreSessionID: nil
        )
        var cache = AgentChatEndedTranscriptListabilityCache()

        let initiallyListable = cache.shouldList(
            record,
            resolver: resolver,
            now: Date(timeIntervalSince1970: 10)
        )
        #expect(!initiallyListable)

        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        let beforeRetryWindowListable = cache.shouldList(
            record,
            resolver: resolver,
            now: Date(timeIntervalSince1970: 14)
        )
        #expect(!beforeRetryWindowListable)

        let eventuallyListable = cache.shouldList(
            record,
            resolver: resolver,
            now: Date(timeIntervalSince1970: 16)
        )
        #expect(eventuallyListable)
    }

    @MainActor
    @Test func observeScanDoesNotReviveEndedRecordForSamePID() throws {
        let registry = AgentChatSessionRegistry()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            ppid: 303,
            receivedAt: Date(timeIntervalSince1970: 20)
        ))
        registry.update(sessionID: sessionID) { record in
            record.state = .ended
            record.pid = 303
        }
        let ended = try #require(registry.record(sessionID: sessionID))
        let observed = ObservedAgentSession(
            sessionID: sessionID,
            agentKind: .claude,
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            pid: 303,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            sampledAt: Date(timeIntervalSince1970: 30)
        )

        let revived = registry.reviveEndedObservedSessionIfNeeded(
            current: ended,
            observed: observed,
            now: Date(timeIntervalSince1970: 31)
        )

        #expect(!revived)
        #expect(registry.record(sessionID: sessionID)?.state == .ended)
    }

    @MainActor
    @Test func unlistableEndedSessionPushesRemovalInsteadOfEndedDescriptor() throws {
        let home = try temporaryHomeDirectory()
        let coding = ChatWireCoding()
        var emitted: [ChatSessionEventFrame] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { true },
            emitEventPayload: { payload in
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      let frame = try? coding.decode(ChatSessionEventFrame.self, from: data) else {
                    return
                }
                emitted.append(frame)
            }
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let missingTranscript = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")

        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: missingTranscript.path,
            cwd: "/Users/example/project",
            ppid: 111,
            receivedAt: Date(timeIntervalSince1970: 270)
        ))
        emitted.removeAll()
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionEnd,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: missingTranscript.path,
            cwd: "/Users/example/project",
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 271)
        ))

        #expect(emitted.contains { frame in
            guard case .sessionRemoved = frame.event else { return false }
            return frame.sessionID == sessionID
        })
        #expect(!emitted.contains { frame in
            guard case .stateChanged(.ended) = frame.event else { return false }
            return frame.sessionID == sessionID
        })
        #expect(!emitted.contains { frame in
            guard case .descriptorChanged(let descriptor) = frame.event else { return false }
            return frame.sessionID == sessionID && descriptor.state == .ended
        })
    }

    @MainActor
    @Test func endedCodexSessionPushesEndedStateInsteadOfRemoval() throws {
        let coding = ChatWireCoding()
        var emitted: [ChatSessionEventFrame] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { true },
            emitEventPayload: { payload in
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      let frame = try? coding.decode(ChatSessionEventFrame.self, from: data) else {
                    return
                }
                emitted.append(frame)
            }
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString

        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            ppid: 111,
            receivedAt: Date(timeIntervalSince1970: 280)
        ))
        emitted.removeAll()
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionEnd,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 281)
        ))

        #expect(!emitted.contains { frame in
            guard case .sessionRemoved = frame.event else { return false }
            return frame.sessionID == sessionID
        })
        #expect(emitted.contains { frame in
            guard case .stateChanged(.ended) = frame.event else { return false }
            return frame.sessionID == sessionID
        })
    }

    private func temporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
