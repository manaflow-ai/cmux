import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CommandPaletteSearchEngineTests: XCTestCase {
    private struct FixtureEntry {
        let id: String
        let rank: Int
        let title: String
        let searchableTexts: [String]
    }

    private struct FixtureResult: Equatable {
        let id: String
        let rank: Int
        let title: String
        let score: Int
        let titleMatchIndices: Set<Int>
    }

    private func makeCommandEntries(count: Int) -> [FixtureEntry] {
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

    private func makeSwitcherEntries(count: Int) -> [FixtureEntry] {
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

    private func makeFinderCommandEntries() -> [FixtureEntry] {
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

    private func optimizedResults(
        entries: [FixtureEntry],
        query: String
    ) -> [FixtureResult] {
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }

        return CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
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

    private func legacyResults(
        entries: [FixtureEntry],
        query: String
    ) -> [FixtureResult] {
        let queryIsEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let results: [FixtureResult] = queryIsEmpty
            ? entries.map { entry in
                FixtureResult(id: entry.id, rank: entry.rank, title: entry.title, score: 0, titleMatchIndices: [])
            }
            : entries.compactMap { entry in
                guard let fuzzyScore = CommandPaletteFuzzyMatcher.score(
                    query: query,
                    candidates: entry.searchableTexts
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

    private func benchmarkElapsedMs(operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000
    }

    private func repeatedQueries(_ baseQueries: [String], repetitions: Int) -> [String] {
        Array(repeating: baseQueries, count: repetitions).flatMap { $0 }
    }

    func testOptimizedSearchMatchesLegacyPipeline() {
        let commandEntries = makeCommandEntries(count: 96)
        let switcherEntries = makeSwitcherEntries(count: 64)
        let queries = [
            "rename",
            "rename tab",
            "workspace",
            "feature-12",
            "3004",
            "toggle side",
            "open dir",
            "phoenix",
            "apply update",
        ]

        for query in queries {
            XCTAssertEqual(
                optimizedResults(entries: commandEntries, query: query),
                legacyResults(entries: commandEntries, query: query),
                "Command corpus mismatch for query \(query)"
            )
            XCTAssertEqual(
                optimizedResults(entries: switcherEntries, query: query),
                legacyResults(entries: switcherEntries, query: query),
                "Switcher corpus mismatch for query \(query)"
            )
        }
    }

    func testSearchCancellationReturnsNoResults() {
        let entries = makeCommandEntries(count: 512)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        var cancellationChecks = 0

        let results = CommandPaletteSearchEngine.search(
            entries: corpus,
            query: "rename"
        ) { _, _ in
            0
        } shouldCancel: {
            cancellationChecks += 1
            return cancellationChecks >= 4
        }

        XCTAssertTrue(results.isEmpty)
        XCTAssertGreaterThanOrEqual(cancellationChecks, 4)
    }

    func testCommandPreviewSearchUsesFullCommandCorpus() {
        let entries = [
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
        ]
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let corpusByID = Dictionary(uniqueKeysWithValues: corpus.map { ($0.payload, $0) })

        let previewCommandIDs = ContentView.commandPaletteCommandPreviewMatchCommandIDsForTests(
            searchCorpus: corpus,
            candidateCommandIDs: ["command.find"],
            searchCorpusByID: corpusByID,
            query: "finde",
            resultLimit: 48
        )

        XCTAssertEqual(previewCommandIDs.first, "command.finder")
    }

    func testSearchMatchesSingleOmittedCharacterInCommandWordPrefix() {
        let entries = makeFinderCommandEntries()

        XCTAssertEqual(
            optimizedResults(entries: entries, query: "findr").first?.id,
            "command.finder"
        )
    }

    func testSearchMatchesSingleInsertedCharacterInCommandWordPrefix() {
        let entries = makeFinderCommandEntries()

        XCTAssertEqual(
            optimizedResults(entries: entries, query: "findder").first?.id,
            "command.finder"
        )
    }

    func testSearchMatchesSingleSubstitutedCharacterInCommandWordPrefix() {
        let entries = makeFinderCommandEntries()

        XCTAssertEqual(
            optimizedResults(entries: entries, query: "fander").first?.id,
            "command.finder"
        )
    }

    func testSearchMatchesSingleTransposedCharacterInCommandWordPrefix() {
        let entries = makeFinderCommandEntries()

        XCTAssertEqual(
            optimizedResults(entries: entries, query: "fidner").first?.id,
            "command.finder"
        )
    }

    func testSearchRejectsMultipleEditsInCommandWordPrefix() {
        let entries = makeFinderCommandEntries()

        XCTAssertNotEqual(
            optimizedResults(entries: entries, query: "fadnr").first?.id,
            "command.finder"
        )
    }

    func testResolvedSelectionIndexPrefersAnchoredCommand() {
        let resultIDs = ["command.0", "command.1", "command.2"]

        XCTAssertEqual(
            ContentView.commandPaletteResolvedSelectionIndex(
                preferredCommandID: "command.2",
                fallbackSelectedIndex: 0,
                resultIDs: resultIDs
            ),
            2
        )
        XCTAssertEqual(
            ContentView.commandPaletteResolvedSelectionIndex(
                preferredCommandID: "missing",
                fallbackSelectedIndex: 9,
                resultIDs: resultIDs
            ),
            2
        )
        XCTAssertEqual(
            ContentView.commandPaletteResolvedSelectionIndex(
                preferredCommandID: nil,
                fallbackSelectedIndex: 1,
                resultIDs: []
            ),
            0
        )
    }

    func testResolvedPendingActivationPreservesSubmitAndClickSemantics() {
        let resultIDs = ["command.0", "command.1", "command.2"]

        XCTAssertEqual(
            ContentView.commandPaletteResolvedPendingActivation(
                .selected(requestID: 41, fallbackSelectedIndex: 0, preferredCommandID: "command.2"),
                requestID: 41,
                resultIDs: resultIDs
            ),
            .selected(index: 2)
        )
        XCTAssertEqual(
            ContentView.commandPaletteResolvedPendingActivation(
                .command(requestID: 41, commandID: "command.1"),
                requestID: 41,
                resultIDs: resultIDs
            ),
            .command(commandID: "command.1")
        )
        XCTAssertNil(
            ContentView.commandPaletteResolvedPendingActivation(
                .command(requestID: 41, commandID: "missing"),
                requestID: 41,
                resultIDs: resultIDs
            )
        )
        XCTAssertNil(
            ContentView.commandPaletteResolvedPendingActivation(
                .selected(requestID: 40, fallbackSelectedIndex: 0, preferredCommandID: nil),
                requestID: 41,
                resultIDs: resultIDs
            )
        )
    }

    func testSelectionAnchorTracksVisiblePendingSelection() {
        let resultIDs = ["command.0", "command.1", "command.2"]
        let visibleAnchor = ContentView.commandPaletteSelectionAnchorCommandID(
            selectedIndex: 2,
            resultIDs: resultIDs
        )

        XCTAssertEqual(
            ContentView.commandPaletteResolvedPendingActivation(
                .selected(
                    requestID: 41,
                    fallbackSelectedIndex: 0,
                    preferredCommandID: visibleAnchor
                ),
                requestID: 41,
                resultIDs: resultIDs
            ),
            .selected(index: 2)
        )
    }

    func testPreviewCandidateCommandIDsAreBounded() {
        let resultIDs = (0..<500).map { "command.\($0)" }

        let previewCandidateIDs = ContentView.commandPalettePreviewCandidateCommandIDs(
            resultIDs: resultIDs,
            limit: 192
        )

        XCTAssertEqual(previewCandidateIDs.count, 192)
        XCTAssertEqual(previewCandidateIDs.first, "command.0")
        XCTAssertEqual(previewCandidateIDs.last, "command.191")
    }

    func testSynchronousSeedRunsOnlyWhenScopeChanges() {
        XCTAssertTrue(
            ContentView.commandPaletteShouldSynchronouslySeedResults(
                hasVisibleResultsForScope: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldSynchronouslySeedResults(
                hasVisibleResultsForScope: true
            )
        )
    }

    func testCommandContextFingerprintTracksExactContextValues() {
        let base = ContentView.commandPaletteContextFingerprint(
            boolValues: [
                "workspace.hasPullRequests": true,
                "panel.hasUnread": false,
                "panel.isTerminal": true,
            ],
            stringValues: [
                "workspace.name": "Alpha",
                "panel.name": "Main",
            ]
        )
        let unreadChanged = ContentView.commandPaletteContextFingerprint(
            boolValues: [
                "workspace.hasPullRequests": true,
                "panel.hasUnread": true,
                "panel.isTerminal": true,
            ],
            stringValues: [
                "workspace.name": "Alpha",
                "panel.name": "Main",
            ]
        )
        let renamed = ContentView.commandPaletteContextFingerprint(
            boolValues: [
                "workspace.hasPullRequests": true,
                "panel.hasUnread": false,
                "panel.isTerminal": true,
            ],
            stringValues: [
                "workspace.name": "Alpha",
                "panel.name": "Logs",
            ]
        )

        XCTAssertNotEqual(base, unreadChanged)
        XCTAssertNotEqual(base, renamed)
    }

    func testSwitcherFingerprintTracksMetadataValuesAtSameCardinality() {
        let windowID = UUID()
        let workspaceID = UUID()
        let base = ContentView.commandPaletteSwitcherFingerprint(
            windowContexts: [
                ContentView.CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: "Window 2",
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        ContentView.CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(
                                directories: ["/Users/example/dev/cmuxterm"],
                                branches: ["feature/search-speed"],
                                ports: [3000]
                            )
                        )
                    ]
                )
            ]
        )
        let changedMetadata = ContentView.commandPaletteSwitcherFingerprint(
            windowContexts: [
                ContentView.CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: "Window 2",
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        ContentView.CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(
                                directories: ["/Users/example/dev/other"],
                                branches: ["feature/search-speed"],
                                ports: [4000]
                            )
                        )
                    ]
                )
            ]
        )
        let changedDisplayName = ContentView.commandPaletteSwitcherFingerprint(
            windowContexts: [
                ContentView.CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: "Window 2",
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        ContentView.CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Beta",
                            metadata: CommandPaletteSwitcherSearchMetadata(
                                directories: ["/Users/example/dev/cmuxterm"],
                                branches: ["feature/search-speed"],
                                ports: [3000]
                            )
                        )
                    ]
                )
            ]
        )

        XCTAssertNotEqual(base, changedMetadata)
        XCTAssertNotEqual(base, changedDisplayName)
    }

    func testCommandSearchBenchmarkBeatsLegacyPipeline() {
        let entries = makeCommandEntries(count: 900)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let queries = repeatedQueries(
            ["rename", "rename tab", "open dir", "toggle side", "apply update", "notif", "split right", "cmux"],
            repetitions: 12
        )

        for query in queries.prefix(8) {
            _ = legacyResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
        }

        let legacyMs = benchmarkElapsedMs {
            for query in queries {
                _ = legacyResults(entries: entries, query: query)
            }
        }
        let optimizedMs = benchmarkElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+shift+p legacy=%.2fms optimized=%.2fms", legacyMs, optimizedMs))
        XCTAssertLessThan(
            optimizedMs,
            legacyMs * 1.25,
            "Optimized command search regressed significantly: legacy=\(legacyMs) optimized=\(optimizedMs)"
        )
    }

    func testSwitcherSearchBenchmarkBeatsLegacyPipeline() {
        let entries = makeSwitcherEntries(count: 400)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let queries = repeatedQueries(
            ["workspace 12", "phoenix", "feature-18", "rename-tab", "3007", "9202", "switch", "worktrees"],
            repetitions: 12
        )

        for query in queries.prefix(8) {
            _ = legacyResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
        }

        let legacyMs = benchmarkElapsedMs {
            for query in queries {
                _ = legacyResults(entries: entries, query: query)
            }
        }
        let optimizedMs = benchmarkElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+p legacy=%.2fms optimized=%.2fms", legacyMs, optimizedMs))
        XCTAssertLessThan(
            optimizedMs,
            legacyMs * 1.25,
            "Optimized switcher search regressed significantly: legacy=\(legacyMs) optimized=\(optimizedMs)"
        )
    }
}
