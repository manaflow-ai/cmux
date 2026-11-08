import CmuxAgentChat
import CmuxMobileHost
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Ranking and row collapsing that agent session search relies on.
@Suite("Search index agent sessions")
struct SearchIndexAgentSessionTests {
    private let windowID = UUID()
    private let workspaceID = UUID()

    @Test
    func panelShowsOneRowAndPrefersItsSessionDocumentOverItsTitle() async throws {
        let (directory, index) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let panelID = UUID()

        try await index.upsert(document(
            id: SearchIndexDocument.panelStableID(panelID: panelID, kind: .title),
            panelID: panelID,
            kind: .title,
            title: "Token spend review",
            text: "Window 1\ncommand center\nToken spend review"
        ))
        try await index.upsert(document(
            id: SearchIndexDocument.panelStableID(panelID: panelID, kind: .agentSession),
            panelID: panelID,
            kind: .agentSession,
            title: "Token spend review",
            text: "how much did the delphi token spend come to last week"
        ))

        let hits = try await index.search("token spend", limit: 10)
        #expect(hits.map(\.kind) == [.agentSession])
        #expect(hits.first?.panelID == panelID)
        #expect(hits.first?.snippet.contains("delphi token spend") == true)
    }

    @Test(arguments: [
        ("work 4", "Work 2", "Work 2"),
        ("work 2", "lucas", "work 2"),
        ("work 2", "lucas@Lucass-MacBook-Pro-4:~", "work 2"),
        ("work 2", "Terminal", "work 2"),
        ("work 2", "~/code/api", "work 2"),
        ("api", "\u{2733} Fix the login redirect", "Fix the login redirect"),
        ("api", "Claude Code", "api"),
        ("  ", "  ", "Codex"),
    ] as [(String, String, String)])
    func sessionRowsAreTitledByTheirPane(workspaceTitle: String, paneTitle: String, expected: String) {
        #expect(
            GlobalSearchDocuments.agentSessionRowTitle(
                workspaceTitle: workspaceTitle,
                paneTitle: paneTitle,
                agentName: "Codex",
                userName: "lucas"
            ) == expected
        )
    }

    @Test
    func aPunctuatedQueryMatchesAsAPhraseNotAsLooseTokens() async throws {
        let (directory, index) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await index.upsert(document(
            id: "prompt",
            panelID: UUID(),
            kind: .terminal,
            title: "Terminal",
            text: "lucas@Lucass-MacBook-Pro-4:~ 16:44:11 $ ls"
        ))
        try await index.upsert(document(
            id: "session",
            panelID: UUID(),
            kind: .agentSession,
            title: "4+4",
            text: "4+4\n8"
        ))

        let hits = try await index.search("4+4", limit: 10)
        #expect(hits.map(\.id) == ["session"])
        #expect(hits.first?.snippet == "4+4 \u{00B7} 8")
    }

    @Test
    func queryPhrasesLeaveOutPunctuationAroundAWord() {
        #expect(SearchIndex.queryPhrases(for: "(4+4), \"api.ts\"! hello") == ["4+4", "api.ts"])
    }

    @Test
    func titleMatchOutranksOneMentionInALongBody() async throws {
        let (directory, index) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await index.upsert(document(
            id: "titled",
            panelID: UUID(),
            kind: .agentSession,
            title: "User access permissions",
            text: String(repeating: "reviewing the grant list for the team. ", count: 200)
        ))
        try await index.upsert(document(
            id: "mentioned",
            panelID: UUID(),
            kind: .agentSession,
            title: "Snapshot QA",
            text: "one line about access. " + String(repeating: "snapshot rows compared. ", count: 200)
        ))

        let hits = try await index.search("access", limit: 10)
        #expect(hits.map(\.id) == ["titled", "mentioned"])
    }

    @Test
    func prefixQueryMatchesAWordBeingTyped() async throws {
        let (directory, index) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.upsert(document(
            id: "deeptune",
            panelID: UUID(),
            kind: .agentSession,
            title: "Add initiative to DeepTune",
            text: "set up the DeepTune vision verticals pod"
        ))

        let hits = try await index.search("deept", limit: 10)
        #expect(hits.map(\.id) == ["deeptune"])
        #expect(hits.first?.snippet.contains("DeepTune") == true)
    }

    @Test
    func onePerPanelKeepsBestRankOrderAndPanelLessRows() {
        let first = UUID()
        let second = UUID()
        let hits = [
            hit(id: "a-title", panelID: first, kind: .title),
            hit(id: "b-session", panelID: second, kind: .agentSession),
            hit(id: "loose", panelID: nil, kind: .browser),
            hit(id: "a-session", panelID: first, kind: .agentSession),
            hit(id: "b-title", panelID: second, kind: .title),
        ]
        #expect(SearchIndex.onePerPanel(hits, limit: 10).map(\.id) == ["a-session", "b-session", "loose"])
        #expect(SearchIndex.onePerPanel(hits, limit: 2).map(\.id) == ["a-session", "b-session"])
    }

    @Test
    func agentSessionDocumentUsesTheRowTitleAndOnlyTheConversationText() {
        let source = AgentSessionSearchSource(
            sessionID: "s-1",
            agentKind: .claude,
            transcriptPath: "/tmp/s-1.jsonl"
        )
        let panelID = UUID()
        let document = GlobalSearchDocuments.agentSessionDocument(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            location: "Window 1 > research pod",
            source: source,
            title: GlobalSearchDocuments.agentSessionRowTitle(
                workspaceTitle: "research pod",
                paneTitle: "Env linter eval cost estimate",
                agentName: source.agentKind.displayName
            ),
            transcriptText: "what would the eval cost"
        )
        #expect(document.id == SearchIndexDocument.panelStableID(panelID: panelID, kind: .agentSession))
        #expect(document.kind == .agentSession)
        #expect(document.panelID == panelID)
        #expect(document.title == "Env linter eval cost estimate")
        #expect(document.location == "Window 1 > research pod")
        #expect(document.anchor == "Claude")
        #expect(document.text == "what would the eval cost")
    }

    @Test
    func agentSessionDocumentCapsItsText() {
        let source = AgentSessionSearchSource(
            sessionID: "s-2",
            agentKind: .codex,
            transcriptPath: "/tmp/s-2.jsonl"
        )
        let document = GlobalSearchDocuments.agentSessionDocument(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: UUID(),
            location: "Window 1 > workspace",
            source: source,
            title: "Codex",
            transcriptText: String(repeating: "x", count: GlobalSearchIndexingLimits.maxIndexedTextCharacters + 10)
        )
        #expect(document.text.count == GlobalSearchIndexingLimits.maxIndexedTextCharacters)
    }

    @Test
    func codexRolloutIsFoundInTodaysSessionsDirectoryWithoutAPid() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9)))
        let day = home.appendingPathComponent("sessions/2026/10/10", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-2026-10-10T09-00-00-abc-123.jsonl")
        try Data().write(to: rollout)
        try Data().write(to: day.appendingPathComponent("rollout-2026-10-10T09-00-00-abc-1234.jsonl"))
        let record = AgentChatSessionRecord(sessionID: "abc-123", agentKind: .codex, state: .idle, lastActivityAt: now)

        let found = CodexRolloutLookup(record: record, codexHome: home).livePath(now: now)

        #expect(found == rollout.path)
    }

    @MainActor
    @Test
    func aPaneClosedWhileItsSessionIsReadKeepsNothingIndexed() async throws {
        let (directory, index) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = makeTerminalContext()
        let transcripts = StubSessionTranscripts(revision: 1, text: "the quince harvest plan")
        let manager = makeCaptureManager(index: index, transcripts: transcripts)
        let panelID = context.panelID
        await transcripts.setDuringRefresh { @MainActor in
            manager.cancelCaptures(forPanelID: panelID)
        }

        await manager.refreshPanelContent(for: context, index: index)

        let hits = try await index.search("quince", limit: 10)
        #expect(hits.isEmpty)
        await manager.pruneAgentSessionReaders()
        let retained = await transcripts.retainedSessionIDs
        #expect(retained == [])
    }

    @MainActor
    @Test
    func aScrollbackIndexedBesideAnUnchangedSessionIsPurged() async throws {
        let (directory, index) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = makeTerminalContext()
        let transcripts = StubSessionTranscripts(revision: 1, text: "the quince harvest plan")
        let manager = makeCaptureManager(index: index, transcripts: transcripts)
        await manager.refreshPanelContent(for: context, index: index)

        // An overlapping refresh that read the pane before its session had
        // text indexes the scrollback after the session document landed.
        manager.terminalCaptureFingerprints[context.panelID] = 7
        let scrollback = try #require(GlobalSearchDocuments.terminalDocument(for: context, text: "stale scrollback about medlars"))
        try await index.upsert(scrollback)

        await manager.refreshPanelContent(for: context, index: index)

        let stale = try await index.search("medlars", limit: 10)
        #expect(stale.isEmpty)
        let session = try await index.search("quince", limit: 10)
        #expect(session.map(\.kind) == [.agentSession])
    }

    // MARK: - Fixtures

    @MainActor
    private func makeTerminalContext() -> GlobalSearchPanelContext {
        GlobalSearchPanelContext(
            windowID: windowID,
            windowTitle: "Window 1",
            workspaceID: workspaceID,
            workspaceTitle: "orchard",
            panelID: UUID(),
            panelTitle: "Terminal",
            panel: StubAgentPanePanel()
        )
    }

    @MainActor
    private func makeCaptureManager(
        index: SearchIndex,
        transcripts: StubSessionTranscripts
    ) -> GlobalSearchPanelCaptureManager {
        GlobalSearchPanelCaptureManager(
            indexProvider: { index },
            cancelPanelPurge: { _ in },
            agentSessionSource: { _ in
                AgentSessionSearchSource(sessionID: "s-1", agentKind: .claude, transcriptPath: "/tmp/s-1.jsonl")
            },
            agentSessionTranscripts: transcripts
        )
    }

    private func makeIndex() throws -> (URL, SearchIndex) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-search-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = try SearchIndex(databaseURL: directory.appendingPathComponent("search.db", isDirectory: false))
        return (directory, index)
    }

    private func document(
        id: String,
        panelID: UUID,
        kind: GlobalSearchKind,
        title: String,
        text: String
    ) -> SearchIndexDocument {
        SearchIndexDocument(
            id: id,
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            kind: kind,
            title: title,
            location: "Window 1 > workspace",
            anchor: kind.rawValue,
            text: text
        )
    }

    private func hit(id: String, panelID: UUID?, kind: GlobalSearchKind) -> SearchIndexHit {
        SearchIndexHit(
            id: id,
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            kind: kind,
            title: id,
            location: "",
            anchor: "",
            snippet: "",
            rank: 0,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }
}

/// A terminal pane that isn't a live terminal, so a refresh indexes only its
/// agent session.
@MainActor
private final class StubAgentPanePanel: Panel {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    var panelType: PanelType { .terminal }
    var displayTitle: String { "Terminal" }

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
}

/// Session text without transcript files; `duringRefresh` runs while a
/// refresh waits on the read, the way a pane closes mid-read.
private actor StubSessionTranscripts: AgentSessionTranscriptStore {
    private let revision: Int
    private let text: String
    private var duringRefresh: (@MainActor @Sendable () -> Void)?
    private(set) var retainedSessionIDs: Set<String>?

    init(revision: Int, text: String) {
        self.revision = revision
        self.text = text
    }

    func setDuringRefresh(_ action: @escaping @MainActor @Sendable () -> Void) {
        duringRefresh = action
    }

    func refreshedRevision(for source: AgentSessionSearchSource) async -> Int? {
        if let duringRefresh {
            await duringRefresh()
        }
        return revision
    }

    func text(forSessionID sessionID: String) -> String? {
        text
    }

    func retainOnly(sessionIDs: Set<String>) {
        retainedSessionIDs = sessionIDs
    }
}
