import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CommandPaletteSearchEngineTests: XCTestCase {
    struct FixtureEntry {
        let id: String
        let rank: Int
        let title: String
        let searchableTexts: [String]
    }

    struct FixtureResult: Equatable {
        let id: String
        let rank: Int
        let title: String
        let score: Int
        let titleMatchIndices: Set<Int>
    }

    func makeCommandEntries(count: Int) -> [FixtureEntry] {
        (0..<count).map { index in
            let title: String
            let subtitle: String
            let keywords: [String]

            switch index % 8 {
            case 0:
                title = "Rename Workspace \(index)"
                subtitle = "Workspace"
                keywords = ["rename", "workspace", "title", "project", "switch"]
            case 1:
                title = "Rename Tab \(index)"
                subtitle = "Tab"
                keywords = ["rename", "tab", "surface", "title"]
            case 2:
                title = "Open Current Directory in IDE \(index)"
                subtitle = "Terminal"
                keywords = ["open", "directory", "cwd", "ide", "vscode"]
            case 3:
                title = "Toggle Sidebar \(index)"
                subtitle = "Layout"
                keywords = ["toggle", "sidebar", "layout", "panel"]
            case 4:
                title = "Apply Update If Available \(index)"
                subtitle = "Global"
                keywords = ["apply", "update", "install", "upgrade"]
            case 5:
                title = "Restart CLI Listener \(index)"
                subtitle = "Global"
                keywords = ["restart", "cli", "listener", "socket", "cmux"]
            case 6:
                title = "Show Notifications \(index)"
                subtitle = "Notifications"
                keywords = ["notifications", "inbox", "unread", "alerts"]
            default:
                title = "Split Browser Right \(index)"
                subtitle = "Layout"
                keywords = ["split", "browser", "right", "layout", "web"]
            }

            return FixtureEntry(
                id: "command.\(index)",
                rank: index,
                title: title,
                searchableTexts: [title, subtitle] + keywords
            )
        }
    }

    func makeSwitcherEntries(count: Int) -> [FixtureEntry] {
        (0..<count).map { index in
            let title = "Workspace \(index) Phoenix"
            let keywords = CommandPaletteSwitcherSearchIndexer.keywords(
                baseKeywords: ["workspace", "switch", "go", title],
                metadata: CommandPaletteSwitcherSearchMetadata(
                    directories: ["/Users/example/dev/cmuxterm-hq/worktrees/feature-\(index)-rename-tab"],
                    branches: ["feature/rename-tab-\(index)"],
                    ports: [3000 + (index % 20), 9200 + (index % 5)]
                ),
                detail: .workspace
            )
            return FixtureEntry(
                id: "workspace.\(index)",
                rank: index,
                title: title,
                searchableTexts: [title, "Workspace"] + keywords
            )
        }
    }

    func makeLargeWorkspaceSwitcherEntries(count: Int) -> [FixtureEntry] {
        (0..<count).map { index in
            let projectSlug = "project-\(index)-cmd-p-search-performance"
            let worktreeSlug = "feature-\(index)-palette-latency"
            let title = "Workspace \(index) \(projectSlug)"
            let keywords = CommandPaletteSwitcherSearchIndexer.keywords(
                baseKeywords: [
                    "workspace",
                    "switch",
                    "go",
                    "open",
                    title,
                    "Window \((index % 4) + 1)",
                ],
                metadata: CommandPaletteSwitcherSearchMetadata(
                    directories: [
                        "/Users/example/dev/cmuxterm-hq/worktrees/\(worktreeSlug)",
                        "/Users/example/dev/cmuxterm-hq/worktrees/\(worktreeSlug)/repo",
                    ],
                    branches: [
                        "feature/palette-latency-\(index)",
                        "task/cmd-p-search-\(index % 17)",
                    ],
                    ports: [
                        3000 + (index % 50),
                        4200 + (index % 25),
                        9200 + (index % 10),
                    ],
                    description: "Palette performance fixture \(index) for \(projectSlug)"
                ),
                detail: .workspace
            )
            return FixtureEntry(
                id: "workspace.large.\(index)",
                rank: index,
                title: title,
                searchableTexts: [title, "Workspace"] + keywords
            )
        }
    }

    func makeFinderCommandEntries() -> [FixtureEntry] {
        [
            FixtureEntry(
                id: "command.find",
                rank: 0,
                title: "Find...",
                searchableTexts: ["Find...", "Search", "find", "search"]
            ),
            FixtureEntry(
                id: "command.finder",
                rank: 1,
                title: "Open Current Directory in Finder",
                searchableTexts: ["Open Current Directory in Finder", "Terminal", "finder", "directory", "open"]
            ),
            FixtureEntry(
                id: "command.filter",
                rank: 2,
                title: "Filter Sidebar Items",
                searchableTexts: ["Filter Sidebar Items", "Sidebar", "filter", "sidebar", "items"]
            ),
        ]
    }

    func makeUpdateCommandEntries() -> [FixtureEntry] {
        [
            FixtureEntry(
                id: "command.checkForUpdates",
                rank: 0,
                title: "Check for Updates",
                searchableTexts: ["Check for Updates", "Global", "update", "upgrade", "release"]
            ),
            FixtureEntry(
                id: "command.attemptUpdate",
                rank: 1,
                title: "Attempt Update",
                searchableTexts: ["Attempt Update", "Global", "attempt", "check", "update", "upgrade", "release"]
            ),
            FixtureEntry(
                id: "command.applyUpdateIfAvailable",
                rank: 2,
                title: "Apply Update (If Available)",
                searchableTexts: ["Apply Update (If Available)", "Global", "apply", "install", "update", "available"]
            ),
        ]
    }

    func optimizedResults(
        entries: [FixtureEntry],
        query: String,
        resultLimit: Int? = nil
    ) -> [FixtureResult] {
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }

        return CommandPaletteSearchEngine.search(entries: corpus, query: query, resultLimit: resultLimit) { _, _ in 0 }
            .map {
                FixtureResult(
                    id: $0.payload,
                    rank: $0.rank,
                    title: $0.title,
                    score: $0.score,
                    titleMatchIndices: $0.titleMatchIndices
                )
            }
    }

    func referenceResults(
        entries: [FixtureEntry],
        query: String
    ) -> [FixtureResult] {
        let queryIsEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let results: [FixtureResult] = queryIsEmpty
            ? entries.map { entry in
                FixtureResult(id: entry.id, rank: entry.rank, title: entry.title, score: 0, titleMatchIndices: [])
            }
            : entries.compactMap { entry in
                guard let fuzzyScore = weightedReferenceScore(
                    query: query,
                    entry: entry
                ) else {
                    return nil
                }
                return FixtureResult(
                    id: entry.id,
                    rank: entry.rank,
                    title: entry.title,
                    score: fuzzyScore,
                    titleMatchIndices: CommandPaletteFuzzyMatcher.matchCharacterIndices(
                    query: query,
                        candidate: entry.title
                    )
                )
            }

        return results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func fastTypingPrefixes(_ text: String) -> [String] {
        text.indices.map { index in
            String(text[...index])
        }
    }

    func estimatedDroppedFrames(
        for queryDurationsMs: [Double],
        frameBudgetMs: Double = 1000.0 / 60.0
    ) -> Int {
        queryDurationsMs.reduce(0) { total, durationMs in
            total + max(0, Int(ceil(durationMs / frameBudgetMs)) - 1)
        }
    }

    private func weightedReferenceScore(
        query: String,
        entry: FixtureEntry
    ) -> Int? {
        guard let fuzzyScore = CommandPaletteFuzzyMatcher.score(
            query: query,
            candidates: entry.searchableTexts
        ) else {
            return nil
        }
        guard let titleScore = CommandPaletteFuzzyMatcher.score(
            query: query,
            candidate: entry.title
        ) else {
            return fuzzyScore
        }
        return max(fuzzyScore, titleScore + 2000)
    }

    func benchmarkElapsedMs(operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000
    }

    func repeatedQueries(_ baseQueries: [String], repetitions: Int) -> [String] {
        Array(repeating: baseQueries, count: repetitions).flatMap { $0 }
    }

}
