import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
@preconcurrency import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryLifecycleReviewRegressionTests {
    @MainActor
    @Test func liveCodexHookDefersFallbackTranscriptScanUntilHistoryOpen() async throws {
        let home = try temporaryHomeDirectory()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".codex/sessions/2026/07/24", isDirectory: true)
            .appendingPathComponent("rollout-2026-07-24T00-00-00-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            emitEventPayload: { _ in }
        )
        let connection = MobileHostConnection(
            id: UUID(),
            connection: NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: 9)!,
                using: .tcp
            ),
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        await connection.subscribe(
            streamID: "agent-chat-fallback-regression",
            topics: [AgentChatTranscriptService.eventTopic]
        )

        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "codex",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            transcriptPath: nil,
            cwd: "/Users/example/project",
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 300)
        ))
        let recordAfterHook = service.sessionRecord(sessionID: sessionID)
        _ = await connection.unsubscribe(streamID: "agent-chat-fallback-regression")

        let history = await service.history(sessionID: sessionID, beforeSeq: nil, limit: 50)
        let recordAfterHistory = service.sessionRecord(sessionID: sessionID)
        let adoptedHistoryPath = recordAfterHistory?.transcriptPath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }

        #expect(recordAfterHook?.transcriptPath == nil)
        #expect(history != nil)
        #expect(adoptedHistoryPath == transcriptURL.resolvingSymlinksInPath().path)
    }

    @MainActor
    @Test func concurrentCodexHistoryRequestsShareOneFallbackResolution() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = UUID().uuidString.lowercased()
        let transcriptURL = home
            .appendingPathComponent(".codex/sessions/2026/07/24", isDirectory: true)
            .appendingPathComponent("rollout-2026-07-24T00-00-00-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        let probe = AgentChatConcurrentFallbackResolutionProbe(path: transcriptURL.path)
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in },
            fallbackTranscriptPathResolver: { record, deadline in
                await probe.resolve(record: record, deadline: deadline)
            }
        )
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "codex",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            transcriptPath: nil,
            cwd: "/Users/example/project",
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 301)
        ))

        let pageAvailability = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await service.history(
                        sessionID: sessionID,
                        beforeSeq: nil,
                        limit: 50
                    ) != nil
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        #expect(pageAvailability.count == 16)
        #expect(pageAvailability.allSatisfy { $0 })
        #expect(await probe.callCount() == 1)
    }

    @MainActor
    @Test func onlyHookEventsProvideAuthoritativeAgentLifecycleState() throws {
        let registry = AgentChatSessionRegistry()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 123,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            )
        ])

        #expect(registry.record(sessionID: sessionID)?.hasHookLifecycleState == false)

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            ppid: 123
        ))

        #expect(registry.record(sessionID: sessionID)?.hasHookLifecycleState == true)
    }

    @MainActor
    @Test func transcriptInferredIdleIsNotHookAuthoritative() throws {
        let registry = AgentChatSessionRegistry()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            ppid: 123,
            receivedAt: Date(timeIntervalSince1970: 10)
        ))

        registry.noteAssistantTurnCompleted(
            sessionID: sessionID,
            at: Date(timeIntervalSince1970: 11)
        )

        let record = try #require(registry.record(sessionID: sessionID))
        #expect(record.state == .idle)
        #expect(!record.hasHookLifecycleState)
    }

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

private actor AgentChatConcurrentFallbackResolutionProbe {
    private let path: String
    private var calls = 0

    init(path: String) {
        self.path = path
    }

    func resolve(
        record _: AgentChatSessionRecord,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        calls += 1
        for _ in 0..<100 {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            await Task.yield()
        }
        return path
    }

    func callCount() -> Int {
        calls
    }
}
