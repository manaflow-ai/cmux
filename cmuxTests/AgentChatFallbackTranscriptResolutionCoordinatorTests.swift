import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatFallbackTranscriptResolutionCoordinatorTests {
    @MainActor
    @Test func authoritativeTranscriptBindingCancelsFallbackResolution() async throws {
        let fixture = try makeCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let probe = AgentChatFallbackResolutionProbe(path: nil, waitForCancellation: true)
        let service = makeService(fixture: fixture, probe: probe)

        let historyTask = Task {
            await service.history(sessionID: fixture.sessionID, beforeSeq: nil, limit: 50)
        }
        await probe.waitUntilStarted()
        service.registry.update(sessionID: fixture.sessionID) {
            $0.transcriptPath = fixture.transcript.path
        }

        #expect(await historyTask.value != nil)
        #expect(await probe.wasCancelled())
        #expect(await probe.callCount() == 1)
    }

    @MainActor
    @Test func endedSessionCancelsFallbackResolution() async throws {
        let fixture = try makeCodexFixture(createTranscript: false)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let probe = AgentChatFallbackResolutionProbe(path: nil, waitForCancellation: true)
        let service = makeService(fixture: fixture, probe: probe)

        let historyTask = Task {
            await service.history(sessionID: fixture.sessionID, beforeSeq: nil, limit: 50)
        }
        await probe.waitUntilStarted()
        service.noteHookEvent(fixture.hookEvent(.sessionEnd))

        #expect(await historyTask.value == nil)
        #expect(await probe.wasCancelled())
        #expect(await probe.callCount() == 1)
    }

    @MainActor
    @Test func cancelledResolutionDoesNotPublishLateResolverResult() async throws {
        let fixture = try makeCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let probe = AgentChatFallbackResolutionProbe(
            path: fixture.transcript.path,
            waitForCancellation: true,
            returnPathAfterCancellation: true
        )
        let registry = AgentChatSessionRegistry()
        let record = registry.noteHookEvent(fixture.hookEvent(.sessionStart))
        let coordinator = AgentChatFallbackTranscriptResolutionCoordinator(
            transcriptResolver: AgentChatTranscriptResolver(homeDirectory: fixture.home, environment: [:]),
            resolver: { record, deadline in
                await probe.resolve(record: record, deadline: deadline)
            },
            timeout: .milliseconds(250)
        )

        let resolutionTask = Task {
            await coordinator.resolve(for: record)
        }
        await probe.waitUntilStarted()
        let coalescedResolutionTask = Task {
            await coordinator.resolve(for: record)
        }
        await Task.yield()
        coordinator.cancel(sessionID: fixture.sessionID)

        #expect(await resolutionTask.value == nil)
        #expect(await coalescedResolutionTask.value == nil)
        #expect(await probe.wasCancelled())
        #expect(await probe.callCount() == 1)
    }

    @MainActor
    @Test func expiredDeadlineSkipsCodexFallbackEnumeration() throws {
        let fixture = try makeCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let resolver = AgentChatTranscriptResolver(homeDirectory: fixture.home, environment: [:])
        let registry = AgentChatSessionRegistry()
        let record = registry.noteHookEvent(fixture.hookEvent(.sessionStart))

        #expect(resolver.transcriptPath(for: record, deadline: .now) == nil)
    }

    @MainActor
    private func makeService(
        fixture: AgentChatFallbackResolutionFixture,
        probe: AgentChatFallbackResolutionProbe
    ) -> AgentChatTranscriptService {
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: fixture.home, environment: [:]),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in },
            fallbackTranscriptPathResolver: { record, deadline in
                await probe.resolve(record: record, deadline: deadline)
            },
            fallbackResolutionTimeout: .milliseconds(250)
        )
        service.noteHookEvent(fixture.hookEvent(.sessionStart))
        return service
    }

    private func makeCodexFixture(
        createTranscript: Bool = true
    ) throws -> AgentChatFallbackResolutionFixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-chat-\(UUID().uuidString)", isDirectory: true)
        let sessionID = UUID().uuidString.lowercased()
        let transcript = home
            .appendingPathComponent(".codex/sessions/2026/07/24", isDirectory: true)
            .appendingPathComponent("rollout-2026-07-24T00-00-00-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if createTranscript {
            try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)
        }
        return AgentChatFallbackResolutionFixture(
            home: home,
            transcript: transcript,
            sessionID: sessionID,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString
        )
    }
}

private struct AgentChatFallbackResolutionFixture {
    let home: URL
    let transcript: URL
    let sessionID: String
    let workspaceID: String
    let surfaceID: String

    func hookEvent(_ name: WorkstreamEvent.HookEventName) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: name,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: nil,
            cwd: "/Users/example/project",
            ppid: name == .sessionEnd ? nil : 123,
            receivedAt: Date(timeIntervalSince1970: name == .sessionEnd ? 302 : 301)
        )
    }
}

private actor AgentChatFallbackResolutionProbe {
    private let path: String?
    private let waitForCancellation: Bool
    private let returnPathAfterCancellation: Bool
    private var calls = 0
    private var cancelled = false
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        path: String?,
        waitForCancellation: Bool = false,
        returnPathAfterCancellation: Bool = false
    ) {
        self.path = path
        self.waitForCancellation = waitForCancellation
        self.returnPathAfterCancellation = returnPathAfterCancellation
    }

    func resolve(
        record _: AgentChatSessionRecord,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        calls += 1
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if waitForCancellation {
            while !Task.isCancelled, ContinuousClock.now < deadline {
                await Task.yield()
            }
            cancelled = Task.isCancelled
            return returnPathAfterCancellation ? path : nil
        }
        return path
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func callCount() -> Int {
        calls
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}
