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
    func agentSessionDocumentUsesTheSessionTitleAndOnlyTheConversationText() {
        let source = AgentSessionSearchSource(
            sessionID: "s-1",
            agentKind: .claude,
            transcriptPath: "/tmp/s-1.jsonl",
            paneTitle: nil,
            conversationTitle: "Env linter eval cost estimate"
        )
        let panelID = UUID()
        let document = GlobalSearchDocuments.agentSessionDocument(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            location: "Window 1 > research pod",
            source: source,
            title: source.title(firstPrompt: "what would the eval cost"),
            transcriptText: "what would the eval cost"
        )
        #expect(document.id == SearchIndexDocument.panelStableID(panelID: panelID, kind: .agentSession))
        #expect(document.kind == .agentSession)
        #expect(document.panelID == panelID)
        #expect(document.title == "Env linter eval cost estimate")
        #expect(document.location == "Window 1 > research pod")
        #expect(document.anchor == "s-1")
        #expect(document.text == "what would the eval cost")
    }

    @Test
    func agentSessionDocumentCapsItsText() {
        let source = AgentSessionSearchSource(
            sessionID: "s-2",
            agentKind: .codex,
            transcriptPath: "/tmp/s-2.jsonl",
            paneTitle: nil,
            conversationTitle: nil
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

    @Test(arguments: [
        ("✳ Fix the login redirect", "first prompt", "Fix the login redirect"),
        ("  ◐  ", "Why does the build fail", "Why does the build fail"),
        ("✶", nil, "Claude"),
    ] as [(String, String?, String)])
    func sessionTitlePrefersThePaneTitleWithoutSpinnerGlyphs(
        paneTitle: String,
        conversationTitle: String?,
        expected: String
    ) {
        let title = AgentChatTranscriptService.globalSearchTitle(
            paneTitle: paneTitle,
            conversationTitle: conversationTitle,
            agentName: "Claude"
        )
        #expect(title == expected)
    }

    @Test(arguments: [
        ("why does the build fail\non CI only", "why does the build fail"),
        ("\n  1+1  ", "1+1"),
        (String(repeating: "a", count: 81), String(repeating: "a", count: 80) + "\u{2026}"),
    ] as [(String, String)])
    func untitledSessionsAreNamedByTheirFirstPromptsOpeningLine(firstPrompt: String, expected: String) {
        let title = AgentChatTranscriptService.globalSearchTitle(
            paneTitle: nil,
            conversationTitle: nil,
            firstPrompt: firstPrompt,
            agentName: "Codex"
        )
        #expect(title == expected)
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

        let found = AgentChatTranscriptService.liveCodexRolloutPath(for: record, now: now, codexHome: home)

        #expect(found == rollout.path)
    }

    // MARK: - Fixtures

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
