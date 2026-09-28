import CMUXAgentLaunch
import CmuxAgentChat
@testable import CmuxMobileHost
import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Fakes

@MainActor
private final class FakeOutlineSource: AgentTurnOutlineSource {
    var snapshot: AgentTurnOutlineSnapshot?
    private var continuations: [AsyncStream<Void>.Continuation] = []

    func turnOutlineChanges(surfaceID: UUID) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations.append(continuation)
        return stream
    }

    func turnOutline(surfaceID: UUID) async -> AgentTurnOutlineSnapshot? {
        snapshot
    }

    func publish(_ titles: [String], agentKind: ChatAgentKind = .claude) {
        snapshot = AgentTurnOutlineSnapshot(
            sessionID: "session",
            agentKind: agentKind,
            entries: titles.enumerated().map { index, title in
                ChatOutlineEntry(
                    id: "entry-\(index)",
                    seq: index * 10,
                    timestamp: Date(timeIntervalSince1970: Double(index)),
                    title: title
                )
            },
            isHeadTruncated: false
        )
        continuations.forEach { $0.yield() }
    }
}

@MainActor
private final class FakeViewport: AgentTurnTerminalViewport {
    var rows: [String] = []
    var offset: UInt64 = 0
    var length: UInt64 = 10
    var revision: UInt64 = 1
    private(set) var scrolls: [(row: Int, isAtBottom: Bool)] = []

    func agentTurnRailGeometry() -> NotificationScrollRestoreGeometry? {
        NotificationScrollRestoreGeometry(
            scrollbar: GhosttyScrollbar(total: UInt64(rows.count), offset: offset, len: length),
            rowSpaceRevision: revision
        )
    }

    func agentTurnRailScreenRows() -> String? {
        rows.joined(separator: "\n")
    }

    func agentTurnRailScroll(toRow row: Int, revision: UInt64, isAtBottom: Bool) -> Bool {
        guard revision == self.revision else { return false }
        scrolls.append((row, isAtBottom))
        offset = UInt64(row)
        return true
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// 60 rows: prompts "alpha" at 5, "beta" at 25, "gamma" at 45.
private func agentScreen() -> [String] {
    (0..<60).map { row in
        switch row {
        case 5: return "> alpha"
        case 25: return "> beta"
        case 45: return "> gamma"
        default: return "output \(row)"
        }
    }
}

// MARK: - Model

@MainActor
@Suite("Agent turn rail model")
struct AgentTurnRailModelTests {
    @Test("the rail shows for an agent session with two or more prompts and follows live updates")
    func visibilityFollowsOutline() async {
        let source = FakeOutlineSource()
        let viewport = FakeViewport()
        let model = AgentTurnRailModel(surfaceID: UUID())
        var visibilityChanges: [Bool] = []
        model.onVisibilityChange = { visibilityChanges.append($0) }

        source.publish(["only prompt"])
        model.start(source: source, viewport: viewport)
        await waitUntil { model.entries.count == 1 }
        #expect(!model.isVisible)

        source.publish(["only prompt", "second prompt"])
        await waitUntil { model.isVisible }
        #expect(model.entries.map(\.title) == ["only prompt", "second prompt"])

        source.snapshot = nil
        await model.refresh()
        #expect(!model.isVisible)
        #expect(visibilityChanges == [true, false])
    }

    @Test("clicking a turn scrolls one row above its prompt")
    func jumpScrollsToPrompt() async {
        let source = FakeOutlineSource()
        let viewport = FakeViewport()
        viewport.rows = agentScreen()
        viewport.offset = 50
        let model = AgentTurnRailModel(surfaceID: UUID())
        source.publish(["alpha", "beta", "gamma"])
        model.start(source: source, viewport: viewport)
        await waitUntil { model.hasResolvedAnchors }

        #expect(await model.jump(toEntryAt: 1))
        #expect(viewport.scrolls.last?.row == 24)
        #expect(model.currentIndex == 1)
    }

    @Test("a prompt missing from scrollback is not jumpable and never scrolls")
    func unanchoredPromptDoesNotScroll() async {
        let source = FakeOutlineSource()
        let viewport = FakeViewport()
        viewport.rows = agentScreen()
        let model = AgentTurnRailModel(surfaceID: UUID())
        source.publish(["cleared before this", "beta", "gamma"])
        model.start(source: source, viewport: viewport)
        await waitUntil { model.hasResolvedAnchors }

        #expect(!model.isJumpable(0))
        #expect(model.isJumpable(1))
        #expect(await model.jump(toEntryAt: 0) == false)
        #expect(viewport.scrolls.isEmpty)
    }

    @Test("previous and next walk prompts, and next after the last returns to the bottom")
    func keyboardNavigation() async {
        let source = FakeOutlineSource()
        let viewport = FakeViewport()
        viewport.rows = agentScreen()
        viewport.offset = 50
        let model = AgentTurnRailModel(surfaceID: UUID())
        source.publish(["alpha", "beta", "gamma"])
        model.start(source: source, viewport: viewport)
        await waitUntil { model.hasResolvedAnchors }

        // Viewport 50..<60 shows the end of "gamma" (prompt at 45 is above it).
        #expect(await model.jumpToPreviousTurn())
        #expect(viewport.scrolls.last?.row == 44)
        #expect(await model.jumpToPreviousTurn())
        #expect(viewport.scrolls.last?.row == 24)
        #expect(await model.jumpToNextTurn())
        #expect(viewport.scrolls.last?.row == 44)
        #expect(await model.jumpToNextTurn())
        #expect(viewport.scrolls.last?.row == 50)
        #expect(viewport.scrolls.last?.isAtBottom == true)
    }

    @Test("a reflow re-resolves rows before jumping")
    func reflowReresolves() async {
        let source = FakeOutlineSource()
        let viewport = FakeViewport()
        viewport.rows = agentScreen()
        let model = AgentTurnRailModel(surfaceID: UUID())
        source.publish(["alpha", "beta", "gamma"])
        model.start(source: source, viewport: viewport)
        await waitUntil { model.hasResolvedAnchors }

        // A resize rewrapped scrollback: two rows were inserted above "beta".
        viewport.rows.insert(contentsOf: ["wrapped", "wrapped"], at: 10)
        viewport.revision += 1
        #expect(await model.jump(toEntryAt: 1))
        #expect(viewport.scrolls.last?.row == 26)
    }
}

// MARK: - Transcript service

@MainActor
@Suite("Agent turn outline from the transcript service")
struct AgentTurnOutlineServiceTests {
    private static func claudeLine(user uuid: String, _ text: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-09-28T10:00:00Z","message":{"role":"user","content":"\#(text)"}}"#
    }

    private static func claudeLine(assistant uuid: String, _ text: String) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","timestamp":"2026-09-28T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    @Test("a surface's live Claude session yields its prompts, and appends wake observers")
    func outlineForSurface() async throws {
        let home = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home.appendingPathComponent("session.jsonl")
        try ([
            Self.claudeLine(user: "u1", "fix the flaky sidebar test"),
            Self.claudeLine(assistant: "a1", "Found it: a race in the reload."),
            Self.claudeLine(user: "u2", "run it again"),
        ].joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home)),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        defer { service.shutdown() }
        let surfaceID = UUID()
        service.noteHookEvent(WorkstreamEvent(
            sessionId: "claude-session",
            hookEventName: .sessionStart,
            source: "claude",
            surfaceId: surfaceID.uuidString,
            transcriptPath: transcript.path
        ))

        #expect(await service.turnOutline(surfaceID: UUID()) == nil)
        let outline = try #require(await service.turnOutline(surfaceID: surfaceID))
        #expect(outline.agentKind == .claude)
        #expect(outline.entries.map(\.title) == ["fix the flaky sidebar test", "run it again"])
        #expect(outline.entries.first?.replyPreview == "Found it: a race in the reload.")

        var changes = service.turnOutlineChanges(surfaceID: surfaceID).makeAsyncIterator()
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.claudeLine(user: "u3", "ship it") + "\n").utf8))
        try handle.close()
        _ = await changes.next()
        var titles: [String] = []
        for _ in 0..<100 {
            titles = await service.turnOutline(surfaceID: surfaceID)?.entries.map(\.title) ?? []
            if titles.count == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(titles.last == "ship it")

        service.noteHookEvent(WorkstreamEvent(
            sessionId: "claude-session",
            hookEventName: .sessionEnd,
            source: "claude",
            surfaceId: surfaceID.uuidString
        ))
        #expect(await service.turnOutline(surfaceID: surfaceID) == nil)
    }
}
