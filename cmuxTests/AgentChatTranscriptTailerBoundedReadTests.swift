import CmuxAgentChat
import CmuxArtifacts
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent chat transcript tailer bounds")
struct AgentChatTranscriptTailerBoundedReadTests {
    @Test("Initial backfill retains a byte-bounded transcript suffix")
    func initialBackfillIsByteBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("session.jsonl")
        let padding = String(repeating: "x", count: 1_000_000)
        let lines = try (0..<6).map { index in
            try claudeUserLine(id: index, content: "marker-\(index)-\(padding)")
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)

        let tailer = AgentChatTranscriptTailer(
            sessionID: "session",
            agentKind: .claude,
            path: transcript.path
        ) { _ in }
        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: 20)
        await tailer.stop()

        #expect(page.messages.count < lines.count)
        guard let last = page.messages.last,
              case .prose(let prose) = last.kind else {
            Issue.record("Expected the newest retained transcript line")
            return
        }
        #expect(prose.text.hasPrefix("marker-5-"))
        #expect(page.hasMore)
    }

    @Test(.timeLimit(.minutes(1)))
    func incrementalGrowthDiscardsOversizedLineAndResynchronizes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-growth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("session.jsonl")
        try Data().write(to: transcript)
        let batches = AsyncStream<AgentChatTranscriptTailer.Batch>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        defer { batches.continuation.finish() }
        let tailer = AgentChatTranscriptTailer(
            sessionID: "session",
            agentKind: .claude,
            path: transcript.path
        ) { batch in
            batches.continuation.yield(batch)
        }
        await tailer.start()

        let oversized = try claudeUserLine(
            id: 0,
            content: String(
                repeating: "x",
                count: AgentChatTranscriptInitialTailReader.defaultMaximumBytes + 1_024
            )
        )
        let survivor = try claudeUserLine(id: 1, content: "survivor")
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(oversized)\n\(survivor)\n".utf8))

        var iterator = batches.stream.makeAsyncIterator()
        var observedSurvivor = false
        while let batch = await iterator.next() {
            observedSurvivor = batch.appended.contains { message in
                guard case .prose(let prose) = message.kind else { return false }
                return prose.text == "survivor"
            }
            if observedSurvivor { break }
        }
        let page = await tailer.history(beforeSeq: nil, limit: 20)
        await tailer.stop()

        #expect(observedSurvivor)
        #expect(page.messages.count == 1)
        #expect(page.messages.first?.seq == 1)
        #expect(page.hasMore)
    }

    private func claudeUserLine(id: Int, content: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "isSidechain": false,
            "uuid": "user-\(id)",
            "timestamp": "2026-07-22T12:00:00.000Z",
            "message": ["role": "user", "content": content],
        ])
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("Agent chat transcript tailer ownership")
@MainActor
struct AgentChatTranscriptTailerOwnershipTests {
    @Test("Automatic-capture tailers are capped with least-recently-used eviction")
    func automaticCaptureTailersAreCappedAndEvictedByRecency() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { true },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: LocalArtifactRepository())
            ),
            isAutomaticArtifactCaptureEnabled: { true }
        )
        let expectedCap = 32
        let total = expectedCap + 1

        try makeTranscript(at: root, index: 0)
        noteSession(index: 0, root: root, service: service)
        try makeTranscript(at: root, index: 1)
        noteSession(index: 1, root: root, service: service)

        // Touch the first session after the second one was created. The second
        // session should therefore be the first artifact-only tailer evicted.
        if let first = service.registry.record(sessionID: sessionID(index: 0)) {
            service.ensureTailerForEagerObservation(for: first)
        }
        for index in 2..<total {
            try makeTranscript(at: root, index: index)
            noteSession(index: index, root: root, service: service)
        }

        #expect(service.tailers.count == expectedCap)
        #expect(service.tailers[sessionID(index: 0)] != nil)
        #expect(service.tailers[sessionID(index: 1)] == nil)

        await stopRemainingTailers(in: service)
    }

    @Test("Explicit mobile tailers stay outside the artifact-only cap")
    func explicitMobileTailersStayOutsideArtifactCap() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var hasSubscribers = true
        var captureEnabled = true
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { hasSubscribers },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: LocalArtifactRepository())
            ),
            isAutomaticArtifactCaptureEnabled: { captureEnabled }
        )

        try makeTranscript(at: root, index: 0)
        noteSession(index: 0, root: root, service: service)
        if let record = service.registry.record(sessionID: sessionID(index: 0)) {
            _ = service.ensureTailer(for: record)
        }
        hasSubscribers = false
        for index in 1...32 {
            try makeTranscript(at: root, index: index)
            noteSession(index: index, root: root, service: service)
        }

        #expect(service.tailers[sessionID(index: 0)] != nil)

        captureEnabled = false
        service.reconcileAutomaticArtifactCaptureAvailability()

        #expect(service.tailers.count == 1)
        #expect(service.tailers[sessionID(index: 0)] != nil)

        await stopRemainingTailers(in: service)
    }

    @Test("A global subscriber does not promote unrelated eager tailers")
    func globalSubscriberDoesNotPromoteUnrelatedTailers() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { true },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: LocalArtifactRepository())
            ),
            isAutomaticArtifactCaptureEnabled: { true }
        )
        for index in 0...Self.artifactTailerCap {
            try makeTranscript(at: root, index: index)
            noteSession(index: index, root: root, service: service)
        }

        #expect(service.tailers.count == Self.artifactTailerCap)
        #expect(service.tailerOwnership.values.allSatisfy { $0 == .automaticArtifactCapture })

        await stopRemainingTailers(in: service)
    }

    private static let artifactTailerCap = 32

    @Test("Ending a session removes its tailer ownership")
    func endingSessionReleasesTailer() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = try makeTranscript(at: root, index: 0)
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { true }
        )
        let session = WorkstreamEvent(
            sessionId: sessionID(index: 0),
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: transcript.path,
            cwd: root.path,
            ppid: nil,
            receivedAt: .now
        )
        service.noteHookEvent(session)
        #expect(service.tailers[sessionID(index: 0)] != nil)

        service.noteHookEvent(WorkstreamEvent(
            sessionId: session.sessionId,
            hookEventName: .sessionEnd,
            source: session.source,
            workspaceId: session.workspaceId,
            surfaceId: session.surfaceId,
            transcriptPath: session.transcriptPath,
            cwd: session.cwd,
            ppid: nil,
            receivedAt: .now
        ))

        #expect(service.tailers[sessionID(index: 0)] == nil)
        await stopRemainingTailers(in: service)
    }

    private func makeArtifactCaptureService() -> AgentChatTranscriptService {
        AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: LocalArtifactRepository())
            ),
            isAutomaticArtifactCaptureEnabled: { true }
        )
    }

    private func noteSession(
        index: Int,
        root: URL,
        service: AgentChatTranscriptService
    ) {
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID(index: index),
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: root.appendingPathComponent("session-\(index).jsonl").path,
            cwd: root.path,
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
        ))
    }

    private func makeTranscript(at root: URL, index: Int) throws -> URL {
        let transcript = root.appendingPathComponent("session-\(index).jsonl")
        try Data().write(to: transcript)
        return transcript
    }

    private func sessionID(index: Int) -> String {
        "tailer-session-\(index)"
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tailers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stopRemainingTailers(in service: AgentChatTranscriptService) async {
        for tailer in service.tailers.values {
            await tailer.stop()
        }
    }
}
