import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Acceptance fixture for command-palette ranking quality (issue #5033).
///
/// Drives a curated set of `(query → expected top commandID)` cases through
/// ``CommandPaletteSearchOrchestrator/resolvedSearchMatches(searchIndex:searchCorpus:searchCorpusByID:query:usageHistory:queryIsEmpty:historyTimestamp:additionalScoreBoost:resultLimit:shouldCancel:)``
/// using the deterministic Swift scoring path (`searchIndex: nil`, no Nucleo
/// dylib dependency). The contract from the issue's "Measurement / acceptance"
/// section is that plausible queries land the right command in row 1 at
/// least 95% of the time.
@Suite struct CommandPaletteRankingFixtureTests {
    private struct FixtureEntry {
        let id: String
        let rank: Int
        let title: String
        let keywords: [String]
    }

    private struct RankingCase {
        let query: String
        let expected: String
        /// Human-readable note describing the frustration pattern this case
        /// guards against (acronym, typo, abbreviation, ambiguous prefix, …).
        let pattern: String
    }

    /// A corpus modeled on real cmux command-palette entries. IDs are local to
    /// this fixture; the titles/keywords mirror the shapes users actually type
    /// against (Title Case, multi-word, separator-rich keyword lists).
    private static let fixtureEntries: [FixtureEntry] = [
        FixtureEntry(id: "palette.newWorkspace", rank: 0, title: "New Workspace",
                     keywords: ["create", "new", "workspace", "project"]),
        FixtureEntry(id: "palette.newTab", rank: 1, title: "New Tab",
                     keywords: ["create", "new", "tab", "surface"]),
        FixtureEntry(id: "palette.newWindow", rank: 2, title: "New Window",
                     keywords: ["create", "new", "window"]),
        FixtureEntry(id: "palette.closeTab", rank: 3, title: "Close Tab",
                     keywords: ["close", "tab", "dismiss"]),
        FixtureEntry(id: "palette.toggleSidebar", rank: 4, title: "Toggle Sidebar",
                     keywords: ["toggle", "sidebar", "layout", "panel"]),
        FixtureEntry(id: "palette.toggleRightSidebar", rank: 5, title: "Toggle Right Sidebar",
                     keywords: ["toggle", "right", "sidebar", "inspector"]),
        FixtureEntry(id: "palette.settings", rank: 6, title: "Settings",
                     keywords: ["settings", "preferences", "config", "options"]),
        FixtureEntry(id: "palette.copyWorkingDirectory", rank: 7, title: "Copy Working Directory",
                     keywords: ["copy", "working", "directory", "cwd", "path"]),
        FixtureEntry(id: "palette.openInFinder", rank: 8, title: "Open Current Directory in Finder",
                     keywords: ["open", "current", "directory", "finder", "reveal"]),
        FixtureEntry(id: "palette.splitRight", rank: 9, title: "Split Right",
                     keywords: ["split", "right", "pane", "vertical"]),
        FixtureEntry(id: "palette.splitDown", rank: 10, title: "Split Down",
                     keywords: ["split", "down", "pane", "horizontal"]),
        FixtureEntry(id: "palette.renameTab", rank: 11, title: "Rename Tab",
                     keywords: ["rename", "tab", "title"]),
        FixtureEntry(id: "palette.renameWorkspace", rank: 12, title: "Rename Workspace",
                     keywords: ["rename", "workspace", "title"]),
        FixtureEntry(id: "palette.reloadConfig", rank: 13, title: "Reload Configuration",
                     keywords: ["reload", "config", "configuration", "refresh"]),
        FixtureEntry(id: "palette.checkForUpdates", rank: 14, title: "Check for Updates",
                     keywords: ["check", "update", "upgrade", "release"]),
        FixtureEntry(id: "palette.showNotifications", rank: 15, title: "Show Notifications",
                     keywords: ["notifications", "inbox", "unread", "alerts"]),
        FixtureEntry(id: "palette.find", rank: 16, title: "Find",
                     keywords: ["find", "search"]),
        FixtureEntry(id: "palette.toggleFullScreen", rank: 17, title: "Toggle Full Screen",
                     keywords: ["toggle", "full", "screen", "fullscreen"]),
        FixtureEntry(id: "palette.clearTerminal", rank: 18, title: "Clear Terminal",
                     keywords: ["clear", "terminal", "reset", "scrollback"]),
        FixtureEntry(id: "palette.nextTab", rank: 19, title: "Next Tab",
                     keywords: ["next", "tab", "forward"]),
        FixtureEntry(id: "palette.previousTab", rank: 20, title: "Previous Tab",
                     keywords: ["previous", "prev", "tab", "back"]),
        FixtureEntry(id: "palette.zoomIn", rank: 21, title: "Zoom In",
                     keywords: ["zoom", "in", "increase", "font", "larger"]),
        FixtureEntry(id: "palette.zoomOut", rank: 22, title: "Zoom Out",
                     keywords: ["zoom", "out", "decrease", "font", "smaller"]),
        FixtureEntry(id: "palette.restartCli", rank: 23, title: "Restart CLI Listener",
                     keywords: ["restart", "cli", "listener", "socket", "cmux"]),
    ]

    /// Plausible queries seeded from the issue's frustration patterns:
    /// exact text, multi-word prefixes, acronyms, typos, mid-word
    /// CamelHumps-style abbreviations, and ambiguous prefixes.
    private static let rankingCases: [RankingCase] = [
        RankingCase(query: "new workspace", expected: "palette.newWorkspace", pattern: "exact multi-word"),
        RankingCase(query: "nws", expected: "palette.newWorkspace", pattern: "acronym"),
        RankingCase(query: "settings", expected: "palette.settings", pattern: "exact"),
        RankingCase(query: "setings", expected: "palette.settings", pattern: "typo (deletion)"),
        RankingCase(query: "setting", expected: "palette.settings", pattern: "prefix"),
        RankingCase(query: "toggle sidebar", expected: "palette.toggleSidebar", pattern: "exact vs longer sibling"),
        RankingCase(query: "tgsb", expected: "palette.toggleSidebar", pattern: "mid-word abbreviation"),
        RankingCase(query: "trsb", expected: "palette.toggleRightSidebar", pattern: "mid-word abbreviation"),
        RankingCase(query: "tgfs", expected: "palette.toggleFullScreen", pattern: "mid-word abbreviation"),
        RankingCase(query: "cwd", expected: "palette.copyWorkingDirectory", pattern: "acronym keyword"),
        RankingCase(query: "reload config", expected: "palette.reloadConfig", pattern: "multi-word prefix"),
        RankingCase(query: "find", expected: "palette.find", pattern: "exact short"),
        RankingCase(query: "check update", expected: "palette.checkForUpdates", pattern: "skip stopword"),
        RankingCase(query: "notifs", expected: "palette.showNotifications", pattern: "keyword prefix"),
        RankingCase(query: "clear term", expected: "palette.clearTerminal", pattern: "multi-word prefix"),
        RankingCase(query: "prev tab", expected: "palette.previousTab", pattern: "alias keyword"),
        RankingCase(query: "zoom in", expected: "palette.zoomIn", pattern: "ambiguous prefix"),
        RankingCase(query: "zoomout", expected: "palette.zoomOut", pattern: "stitched words"),
        RankingCase(query: "restart cli", expected: "palette.restartCli", pattern: "multi-word"),
        RankingCase(query: "rename tab", expected: "palette.renameTab", pattern: "ambiguous prefix"),
        RankingCase(query: "nwt", expected: "palette.newTab", pattern: "acronym"),
        RankingCase(query: "fullscreen", expected: "palette.toggleFullScreen", pattern: "keyword exact"),
        RankingCase(query: "split right", expected: "palette.splitRight", pattern: "ambiguous prefix"),
        RankingCase(query: "rename ws", expected: "palette.renameWorkspace", pattern: "word + abbreviation"),
    ]

    private func corpus() -> [CommandPaletteSearchCorpusEntry<String>] {
        Self.fixtureEntries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: [entry.title] + entry.keywords
            )
        }
    }

    private func topMatch(
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry] = [:],
        historyTimestamp: TimeInterval = 0
    ) -> String? {
        let corpus = corpus()
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        return CommandPaletteSearchOrchestrator.resolvedSearchMatches(
            searchIndex: nil,
            searchCorpus: corpus,
            query: query,
            usageHistory: usageHistory,
            queryIsEmpty: preparedQuery.isEmpty,
            historyTimestamp: historyTimestamp,
            resultLimit: corpus.count
        ).first?.commandID
    }

    @Test func curatedQueriesHitTop1AccuracyTarget() {
        var misses: [String] = []
        for rankingCase in Self.rankingCases {
            let actual = topMatch(query: rankingCase.query)
            if actual != rankingCase.expected {
                misses.append(
                    "\"\(rankingCase.query)\" [\(rankingCase.pattern)] → expected \(rankingCase.expected), got \(actual ?? "<none>")"
                )
            }
        }

        let total = Self.rankingCases.count
        let hits = total - misses.count
        let accuracy = Double(hits) / Double(total)
        #expect(
            accuracy >= 0.95,
            """
            Top-1 accuracy \(String(format: "%.1f%%", accuracy * 100)) (\(hits)/\(total)) below 95% target.
            Misses:
            \(misses.joined(separator: "\n"))
            """
        )
    }

    @Test func recentlyUsedCommandFloatsUpForAmbiguousQuery() {
        // "new" matches New Workspace / New Tab / New Window. With no history the
        // shortest title (New Tab) wins on the prefix-length tie. A user who keeps
        // creating workspaces should see New Workspace float to row 1 via frecency
        // (the usage-history boost wired through historyBoost).
        let baselineTop = topMatch(query: "new")
        #expect(baselineTop == "palette.newTab")

        let usageHistory: [String: CommandPaletteUsageEntry] = [
            "palette.newWorkspace": CommandPaletteUsageEntry(useCount: 12, lastUsedAt: 1_000)
        ]
        let frecencyTop = topMatch(query: "new", usageHistory: usageHistory, historyTimestamp: 1_000)
        #expect(frecencyTop == "palette.newWorkspace")
    }
}
