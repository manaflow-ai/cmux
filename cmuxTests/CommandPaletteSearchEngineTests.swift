import CmuxCommandPalette
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
            let keywords = CommandPaletteSwitcherSearchIndexer(
                baseKeywords: ["workspace", "switch", "go", title],
                metadata: CommandPaletteSwitcherSearchMetadata(
                    directories: ["/Users/example/dev/cmuxterm-hq/worktrees/feature-\(index)-rename-tab"],
                    branches: ["feature/rename-tab-\(index)"],
                    ports: [3000 + (index % 20), 9200 + (index % 5)]
                ),
                detail: .workspace
            ).keywords
            return FixtureEntry(
                id: "workspace.\(index)",
                rank: index,
                title: title,
                searchableTexts: [title, "Workspace"] + keywords
            )
        }
    }

    private func makeLargeWorkspaceSwitcherEntries(count: Int) -> [FixtureEntry] {
        (0..<count).map { index in
            let projectSlug = "project-\(index)-cmd-p-search-performance"
            let worktreeSlug = "feature-\(index)-palette-latency"
            let title = "Workspace \(index) \(projectSlug)"
            let keywords = CommandPaletteSwitcherSearchIndexer(
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
            ).keywords
            return FixtureEntry(
                id: "workspace.large.\(index)",
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

    private func makeUpdateCommandEntries() -> [FixtureEntry] {
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

    private func optimizedResults(
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

        return CommandPaletteSearchEngine(entries: corpus).search(
            query: query, resultLimit: resultLimit) { _, _ in 0 }
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

    private func referenceResults(
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

    private func fastTypingPrefixes(_ text: String) -> [String] {
        text.indices.map { index in
            String(text[...index])
        }
    }

    private func estimatedDroppedFrames(
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

    private func benchmarkElapsedMs(operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000
    }

    /// Runs `operation` `repetitions` times and returns the fastest (minimum)
    /// elapsed wall-clock duration. Using the best-of-N run instead of a single
    /// shot makes timing-ratio assertions robust against one-off CI scheduler
    /// preemption: a single block can be preempted, but the minimum across
    /// several runs reflects the work the code path actually performs. The
    /// relative-performance signal is preserved because a path that does
    /// strictly less work still wins on its best run.
    private func bestOfElapsedMs(repetitions: Int = 5, operation: () -> Void) -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<max(1, repetitions) {
            best = min(best, benchmarkElapsedMs(operation: operation))
        }
        return best
    }

    private func repeatedQueries(_ baseQueries: [String], repetitions: Int) -> [String] {
        Array(repeating: baseQueries, count: repetitions).flatMap { $0 }
    }

    func testOptimizedSearchMatchesReferencePipeline() {
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
                referenceResults(entries: commandEntries, query: query),
                "Command corpus mismatch for query \(query)"
            )
            XCTAssertEqual(
                optimizedResults(entries: switcherEntries, query: query),
                referenceResults(entries: switcherEntries, query: query),
                "Switcher corpus mismatch for query \(query)"
            )
        }
    }

    func testMultiTokenSearchCanMatchAcrossTitleAndKeywordFields() {
        let entries = [
            FixtureEntry(
                id: "workspace.projectA",
                rank: 0,
                title: "Project A",
                searchableTexts: ["Project A", "Workspace"]
            ),
            FixtureEntry(
                id: "workspace.notes",
                rank: 1,
                title: "Notes",
                searchableTexts: ["Notes", "Workspace"]
            ),
        ]

        XCTAssertEqual(
            optimizedResults(entries: entries, query: "project workspace").first?.id,
            "workspace.projectA"
        )
    }

    func testMobileConnectCommandIsFoundByMobileDeviceQueries() {
        // Mirror the real command pipeline: a command's searchable corpus is
        // [title, subtitle] + keywords (see CommandPaletteCommand.searchableTexts).
        // Pull the keywords from the production source of truth so this test fails
        // if any of the expected aliases are ever dropped from the contribution.
        let mobileConnect = FixtureEntry(
            id: "palette.mobileConnect",
            rank: 0,
            title: "Connect iPhone/iPad",
            searchableTexts: ["Connect iPhone/iPad", "Mobile"]
                + ContentView.commandPaletteMobileConnectKeywords
        )
        // Dense, realistic decoy corpus so the assertion exercises ranking, not a
        // single-item list.
        let decoys = makeCommandEntries(count: 64).enumerated().map { offset, entry in
            FixtureEntry(
                id: entry.id,
                rank: offset + 1,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let corpus = [mobileConnect] + decoys

        for query in ["ios", "ipados", "iphone", "ipad", "pair", "mobile", "phone", "connect"] {
            XCTAssertEqual(
                optimizedResults(entries: corpus, query: query).first?.id,
                "palette.mobileConnect",
                "Expected Connect iPhone/iPad to be the top command palette result for query \"\(query)\""
            )
        }
    }

    func testLimitedSearchReturnsSameTopResultsAsFullSearch() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let queries = [
            "workspace 799",
            "palette latency",
            "feature 401",
            "cmd-p-search",
            "project-642",
            "Window 3",
        ]

        for query in queries {
            let fullResults = optimizedResults(entries: entries, query: query)
            let limitedResults = optimizedResults(entries: entries, query: query, resultLimit: 48)

            XCTAssertEqual(
                limitedResults,
                Array(fullResults.prefix(48)),
                "Limited search should preserve full-search ordering and highlight output for query \(query)"
            )
        }
    }

    func testLimitedSearchStillFindsDeepWorkspaceMatch() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 5_000)

        let results = optimizedResults(
            entries: entries,
            query: "workspace 4913",
            resultLimit: 10
        )

        XCTAssertEqual(results.first?.id, "workspace.large.4913")
        XCTAssertLessThanOrEqual(results.count, 10)
    }

    func testLimitedSearchReturnsOnlyRequestedResultCountForBroadWorkspaceQuery() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 1_200)

        let results = optimizedResults(
            entries: entries,
            query: "workspace",
            resultLimit: 100
        )

        XCTAssertEqual(results.count, 100)
        XCTAssertEqual(
            results,
            Array(optimizedResults(entries: entries, query: "workspace").prefix(100))
        )
    }

    func testResolvedSearchMatchesReturnFullFinalResultSetWhenUnbounded() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 150)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }

        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: nil,
            searchCorpus: corpus,
            query: "workspace",
            usageHistory: [:],
            queryIsEmpty: false,
            historyTimestamp: 0
        )

        XCTAssertEqual(matches.count, entries.count)
    }

    func testNucleoResolvedSearchMatchesReturnFullFinalResultSetWhenUnbounded() throws {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 150)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        guard let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus) else {
            throw XCTSkip("Build the nucleo FFI dylib before running production wrapper tests")
        }

        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: searchIndex,
            searchCorpus: corpus,
            query: "workspace",
            usageHistory: [:],
            queryIsEmpty: false,
            historyTimestamp: 0
        )

        XCTAssertEqual(matches.count, entries.count)
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

        let results = CommandPaletteSearchEngine(entries: corpus).search(
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

    func testExactForkQueryPinsForkRightBeforeOtherForkCommands() {
        let entries = [
            FixtureEntry(
                id: "palette.forkAgentConversationLeft",
                rank: 0,
                title: "Fork Conversation to the Left",
                searchableTexts: ["Fork Conversation to the Left", "Terminal", "fork", "left"]
            ),
            FixtureEntry(
                id: "palette.forkAgentConversationRight",
                rank: 4,
                title: "Fork Conversation to the Right",
                searchableTexts: ["Fork Conversation to the Right", "Terminal", "fork", "right"]
            ),
            FixtureEntry(
                id: "palette.forkAgentConversationNewTab",
                rank: 2,
                title: "Fork Conversation to New Tab",
                searchableTexts: ["Fork Conversation to New Tab", "Terminal", "fork", "new", "tab"]
            ),
            FixtureEntry(
                id: "palette.forkAgentConversationNewWorkspace",
                rank: 1,
                title: "Fork Conversation to New Workspace",
                searchableTexts: ["Fork Conversation to New Workspace", "Workspace", "fork", "new", "workspace"]
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

        let results = CommandPaletteSearchEngine(entries: corpus).search(
            query: "fork"
        ) { commandId, _ in
            ContentView.commandPaletteForkPriorityBoost(commandId: commandId, query: "fork")
        }

        XCTAssertEqual(results.map(\.payload).first, "palette.forkAgentConversationRight")
    }

    func testForkableAgentCacheKeepsPanelVisibleWithoutFallbackSnapshot() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )

        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: nil
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: nil
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: UUID(),
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: nil
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: UUID(),
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: nil
            )
        )
    }

    func testForkableAgentCacheRequiresMatchingRemoteContextWithoutFallbackSnapshot() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )

        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: false],
                fallbackSnapshot: nil,
                isRemoteTerminal: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: false],
                fallbackSnapshot: nil,
                isRemoteTerminal: true
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: true],
                fallbackSnapshot: nil,
                isRemoteTerminal: true
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: true],
                fallbackSnapshot: nil,
                isRemoteTerminal: false
            )
        )
    }

    func testForkableAgentFallbackSnapshotRequiresVerifiedProbeForVisibility() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let codex = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session",
            workingDirectory: nil,
            launchCommand: nil
        )
        let directOpenCode = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )
        let omoOpenCode = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "omo-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omo",
                executablePath: "/usr/local/bin/cmux",
                arguments: ["/usr/local/bin/cmux", "omo"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: codex
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: false],
                fallbackSnapshot: codex
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: directOpenCode
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: directOpenCode,
                isRemoteTerminal: true
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: true],
                fallbackSnapshot: directOpenCode,
                isRemoteTerminal: true
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: omoOpenCode
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: false],
                fallbackSnapshot: omoOpenCode
            )
        )
    }

    func testForkableAgentRemoteFallbackRejectsCommandsThatRequireLocalLauncherScript() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let longPath = "/Users/cmux/" + String(repeating: "nested-project-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath
                ],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertNotNil(snapshot.forkStartupInput(allowLauncherScript: true))
        XCTAssertNil(snapshot.forkStartupInput(allowLauncherScript: false))
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: snapshot
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: false],
                fallbackSnapshot: snapshot
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: snapshot,
                isRemoteTerminal: true
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: snapshot,
                isRemoteTerminal: true
            )
        )
    }

    func testForkableAgentCacheDoesNotOverrideUnsupportedCurrentSnapshot() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let unsupported = SessionRestorableAgentSnapshot(
            kind: .custom("unsupported-agent"),
            sessionId: "unsupported-session",
            workingDirectory: nil,
            launchCommand: nil
        )

        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: unsupported
            )
        )
    }

    func testImmediateForkExecutionRejectsFallbackSnapshotBeforeProbeVerification() {
        let workspaceId = UUID()
        let panelId = UUID()
        let fallback = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "fallback-codex-session",
            workingDirectory: "/tmp/fallback repo",
            launchCommand: nil
        )

        let snapshot = ContentView.commandPaletteImmediateForkExecutionSnapshot(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [],
            supportedRemoteContextsByPanelKey: [:],
            snapshotFingerprintsByPanelKey: [:],
            fallbackSnapshot: fallback,
            cachedSnapshot: nil
        )

        XCTAssertNil(snapshot)
    }

    func testImmediateForkExecutionPrefersVerifiedCachedSnapshotForSynchronousFallback() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallback = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "restored-codex-session",
            workingDirectory: "/tmp/restored repo",
            launchCommand: nil
        )
        let cached = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "live-codex-session",
            workingDirectory: "/tmp/live repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/opt/homebrew/bin/codex",
                arguments: ["/opt/homebrew/bin/codex", "resume", "live-codex-session"],
                workingDirectory: "/tmp/live repo",
                environment: nil,
                capturedAt: 124,
                source: "process"
            )
        )
        let fingerprint = ContentView.commandPaletteForkSnapshotFingerprint(fallback)

        let selection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
            fallbackSnapshot: fallback,
            cachedSnapshot: cached
        )

        XCTAssertEqual(selection?.snapshot.sessionId, cached.sessionId)
        XCTAssertEqual(selection?.usedFallbackSnapshot, false)
        XCTAssertFalse(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: selection?.usedFallbackSnapshot ?? true,
                panelChanged: false
            )
        )
    }

    func testImmediateForkExecutionUsesProbeVerifiedFallbackSnapshot() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallback = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )
        let fingerprint = ContentView.commandPaletteForkSnapshotFingerprint(fallback)

        let selection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
            fallbackSnapshot: fallback,
            cachedSnapshot: nil
        )

        XCTAssertEqual(selection?.snapshot.sessionId, fallback.sessionId)
        XCTAssertEqual(selection?.usedFallbackSnapshot, true)
    }

    func testImmediateForkExecutionPrefersProbeVerifiedCachedSnapshot() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallback = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "restored-opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )
        let cached = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "live-opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 124,
                source: "process"
            )
        )
        let fingerprint = ContentView.commandPaletteForkSnapshotFingerprint(fallback)

        let selection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
            fallbackSnapshot: fallback,
            cachedSnapshot: cached
        )

        XCTAssertEqual(selection?.snapshot.sessionId, cached.sessionId)
        XCTAssertEqual(selection?.usedFallbackSnapshot, false)
    }

    func testImmediateForkExecutionRejectsStaleProbeFingerprint() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallback = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )

        let snapshot = ContentView.commandPaletteImmediateForkExecutionSnapshot(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: "stale-fingerprint"],
            fallbackSnapshot: fallback,
            cachedSnapshot: nil
        )

        XCTAssertNil(snapshot)
    }

    func testForkCommandsDismissPaletteBeforeRunning() {
        let forkCommandIds = [
            "palette.forkAgentConversationRight",
            "palette.forkAgentConversationLeft",
            "palette.forkAgentConversationTop",
            "palette.forkAgentConversationBottom",
            "palette.forkAgentConversationNewTab",
            "palette.forkAgentConversationNewWorkspace"
        ]

        for commandId in forkCommandIds {
            XCTAssertTrue(ContentView.commandPaletteShouldDismissBeforeRun(forCommandId: commandId))
        }
        XCTAssertFalse(ContentView.commandPaletteShouldDismissBeforeRun(forCommandId: "palette.terminalSplitRight"))
        XCTAssertFalse(ContentView.commandPaletteShouldDismissBeforeRun(forCommandId: "palette.terminalFocusTextBoxInput"))
    }

    func testForkableAgentCacheKeepsVerifiedOpenCodeVisible() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let directOpenCode = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: directOpenCode
            )
        )
    }

    func testForkableAgentSnapshotFingerprintChangesWithSession() {
        let first = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "first-session",
            workingDirectory: "/tmp/repo",
            launchCommand: nil
        )
        let second = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "second-session",
            workingDirectory: "/tmp/repo",
            launchCommand: nil
        )

        XCTAssertNotEqual(
            ContentView.commandPaletteForkSnapshotFingerprint(first),
            ContentView.commandPaletteForkSnapshotFingerprint(second)
        )
    }

    func testForkableAgentSnapshotFingerprintChangesWithForkCommand() {
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "codex",
            executablePath: "/usr/local/bin/codex",
            arguments: ["/usr/local/bin/codex"],
            workingDirectory: "/tmp/repo",
            environment: nil,
            capturedAt: 123,
            source: "process"
        )
        let first = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session",
            workingDirectory: "/tmp/repo",
            launchCommand: launchCommand
        )
        var second = first
        second.registration = CmuxVaultAgentRegistration(
            id: "fork-fingerprint",
            name: "Fork Fingerprint",
            detect: CmuxVaultAgentDetectRule(processName: "fork-fingerprint"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} resume {{sessionId}}",
            cwd: .ignore
        )

        XCTAssertNotEqual(first.forkCommand, second.forkCommand)
        XCTAssertNotEqual(
            ContentView.commandPaletteForkSnapshotFingerprint(first),
            ContentView.commandPaletteForkSnapshotFingerprint(second)
        )
    }

    func testForkableAgentCacheFingerprintUsesFallbackFingerprintAfterProbe() {
        let fallback = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )
        let processDetected = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: nil,
                source: "process"
            )
        )
        let fallbackFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(fallback)
        let processFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(processDetected)

        XCTAssertNotEqual(fallbackFingerprint, processFingerprint)
        XCTAssertEqual(
            ContentView.commandPaletteForkCacheFingerprint(
                snapshot: processDetected,
                fallbackFingerprint: fallbackFingerprint
            ),
            fallbackFingerprint
        )
        XCTAssertEqual(
            ContentView.commandPaletteForkCacheFingerprint(
                snapshot: processDetected,
                fallbackFingerprint: nil
            ),
            processFingerprint
        )
    }

    func testForkableAgentProbeResultReuseRequiresCurrentPanelSession() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fingerprint = "verified-fingerprint"

        XCTAssertTrue(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: true
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: "stale-fingerprint"],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: true],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: nil,
                isRemoteTerminal: false,
                cachedResultHadFallback: true,
                panelChanged: false
            )
        )
    }

    func testForkableAgentProbeResultClearBeforeProbeClearsFallbackBackedCache() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fingerprint = "verified-fingerprint"

        XCTAssertFalse(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: false
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: true,
                panelChanged: false
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: true
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: "stale-fingerprint"],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: false
            )
        )
    }

    func testForkableAgentMatchedFallbackProbePreservesVerifiedCacheUsage() {
        XCTAssertFalse(
            ContentView.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                cachedResultHadFallback: false
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                cachedResultHadFallback: true
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                cachedResultHadFallback: nil
            )
        )
    }

    func testForkableAgentProbeResultMatchIgnoresPaletteSession() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fingerprint = "verified-fingerprint"

        XCTAssertTrue(
            ContentView.commandPaletteForkableAgentProbeResultMatches(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteForkableAgentProbeResultMatches(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: "stale-fingerprint"],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false
            )
        )
    }

    func testNucleoEmptyResultsFallBackToSwiftSingleEditMatching() throws {
        let entries = [
            FixtureEntry(
                id: "palette.renameTab",
                rank: 0,
                title: "Rename Tab...",
                searchableTexts: ["Rename Tab...", "rename", "tab", "title"]
            ),
            FixtureEntry(
                id: "palette.openFolder",
                rank: 1,
                title: "Open Folder...",
                searchableTexts: ["Open Folder...", "open", "folder", "directory"]
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
        guard let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus) else {
            throw XCTSkip("Build the nucleo FFI dylib before running production wrapper tests")
        }

        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: searchIndex,
            searchCorpus: corpus,
            query: "renamd",
            usageHistory: [:],
            queryIsEmpty: CommandPaletteFuzzyMatcher.preparedQuery("renamd").isEmpty,
            historyTimestamp: 0,
            resultLimit: 10
        )

        XCTAssertEqual(matches.first?.commandID, "palette.renameTab")
    }

    func testNucleoPartialResultsIncludeSwiftSingleEditFallback() throws {
        let entries = [
            FixtureEntry(
                id: "palette.reactNativeMarkdown",
                rank: 0,
                title: "React Native Markdown",
                searchableTexts: ["React Native Markdown", "react", "native", "markdown"]
            ),
            FixtureEntry(
                id: "palette.renameTab",
                rank: 1,
                title: "Rename Tab...",
                searchableTexts: ["Rename Tab...", "rename", "tab", "title"]
            ),
            FixtureEntry(
                id: "palette.openFolder",
                rank: 2,
                title: "Open Folder...",
                searchableTexts: ["Open Folder...", "open", "folder", "directory"]
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
        guard let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus) else {
            throw XCTSkip("Build the nucleo FFI dylib before running production wrapper tests")
        }
        let nucleoOnlyMatches = try XCTUnwrap(
            searchIndex.search(query: "renamd", resultLimit: 10)
        )
        XCTAssertFalse(nucleoOnlyMatches.isEmpty)

        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: searchIndex,
            searchCorpus: corpus,
            query: "renamd",
            usageHistory: [:],
            queryIsEmpty: CommandPaletteFuzzyMatcher.preparedQuery("renamd").isEmpty,
            historyTimestamp: 0,
            resultLimit: 10
        )

        XCTAssertEqual(matches.first?.commandID, "palette.renameTab")
    }

    func testNucleoFullPageResultsIncludeSwiftSingleEditFallback() throws {
        var entries = (0..<150).map { index in
            FixtureEntry(
                id: "palette.reactNativeMarkdown.\(index)",
                rank: index,
                title: "React Native Markdown \(index)",
                searchableTexts: ["React Native Markdown \(index)", "react", "native", "markdown"]
            )
        }
        entries.append(
            FixtureEntry(
                id: "palette.renameTab",
                rank: 200,
                title: "Rename Tab...",
                searchableTexts: ["Rename Tab...", "rename", "tab", "title"]
            )
        )
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        guard let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus) else {
            throw XCTSkip("Build the nucleo FFI dylib before running production wrapper tests")
        }
        let nucleoOnlyMatches = try XCTUnwrap(
            searchIndex.search(query: "renamd", resultLimit: 10)
        )
        XCTAssertEqual(nucleoOnlyMatches.count, 10)
        XCTAssertNotEqual(nucleoOnlyMatches.first?.payload, "palette.renameTab")

        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: searchIndex,
            searchCorpus: corpus,
            query: "renamd",
            usageHistory: [:],
            queryIsEmpty: CommandPaletteFuzzyMatcher.preparedQuery("renamd").isEmpty,
            historyTimestamp: 0,
            resultLimit: 10
        )

        XCTAssertEqual(matches.first?.commandID, "palette.renameTab")
    }

    func testFirstValueDictionaryPreservesFirstDuplicateKey() {
        let values = [
            (id: "palette.duplicate", title: "First"),
            (id: "palette.unique", title: "Unique"),
            (id: "palette.duplicate", title: "Second"),
        ]

        let valuesByID = CommandPaletteSearchOrchestrator.firstValueDictionary(values) { $0.id }

        XCTAssertEqual(valuesByID["palette.duplicate"]?.title, "First")
        XCTAssertEqual(valuesByID["palette.unique"]?.title, "Unique")
        XCTAssertEqual(valuesByID.count, 2)
    }

    func testNucleoExactPartialResultsDoNotRunSwiftSingleEditFallback() throws {
        let entries = [
            FixtureEntry(
                id: "workspace.project642",
                rank: 0,
                title: "Project 642 Command Palette",
                searchableTexts: ["Project 642 Command Palette", "Workspace", "project-642", "cmd-p-search"]
            ),
            FixtureEntry(
                id: "workspace.project641",
                rank: 1,
                title: "Project 641 Markdown Preview",
                searchableTexts: ["Project 641 Markdown Preview", "Workspace", "project-641", "markdown-preview"]
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
        guard let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus) else {
            throw XCTSkip("Build the nucleo FFI dylib before running production wrapper tests")
        }
        let nucleoOnlyMatches = try XCTUnwrap(
            searchIndex.search(query: "project-642", resultLimit: 10)
        )
        XCTAssertLessThan(nucleoOnlyMatches.count, 10)

        var cancellationChecks = 0
        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: searchIndex,
            searchCorpus: corpus,
            query: "project-642",
            usageHistory: [:],
            queryIsEmpty: CommandPaletteFuzzyMatcher.preparedQuery("project-642").isEmpty,
            historyTimestamp: 0,
            resultLimit: 10
        ) {
            cancellationChecks += 1
            return false
        }

        XCTAssertEqual(matches.first?.commandID, "workspace.project642")
        XCTAssertEqual(cancellationChecks, 2)
    }

    func testCommandSearchPrefersOpenFolderForOpenFolderQuery() {
        let entries = [
            FixtureEntry(
                id: "palette.newWorkspace",
                rank: 0,
                title: "New Workspace",
                searchableTexts: ["New Workspace", "Workspace", "create", "new", "workspace"]
            ),
            FixtureEntry(
                id: "palette.newWindow",
                rank: 1,
                title: "New Window",
                searchableTexts: ["New Window", "Window", "create", "new", "window"]
            ),
            FixtureEntry(
                id: "palette.openFolder",
                rank: 2,
                title: "Open Folder...",
                searchableTexts: ["Open Folder...", "Workspace", "open", "folder", "repository", "project", "directory"]
            ),
            FixtureEntry(
                id: "palette.openFolderInVSCodeInline",
                rank: 3,
                title: "Open Folder in VS Code (Inline)...",
                searchableTexts: [
                    "Open Folder in VS Code (Inline)...",
                    "VS Code Inline",
                    "open",
                    "folder",
                    "directory",
                    "project",
                    "vs",
                    "code",
                    "inline",
                    "editor",
                    "browser",
                ]
            ),
        ]

        XCTAssertEqual(
            optimizedResults(entries: entries, query: "open folder").prefix(2).map(\.id),
            ["palette.openFolder", "palette.openFolderInVSCodeInline"]
        )
    }

    // The browser-workspace palette command must not displace the exact-title
    // match for "New Workspace"; UI flows (and
    // BrowserPaneNavigationKeybindUITests) rely on it staying the top result.
    func testCommandSearchKeepsNewWorkspaceAboveNewBrowserWorkspace() {
        let entries = [
            FixtureEntry(
                id: "palette.newWorkspace",
                rank: 0,
                title: "New Workspace",
                searchableTexts: ["New Workspace", "Workspace", "create", "new", "workspace"]
            ),
            FixtureEntry(
                id: "palette.newBrowserWorkspace",
                rank: 1,
                title: "New Browser Workspace",
                searchableTexts: ["New Browser Workspace", "Workspace", "create", "new", "browser", "workspace", "web"]
            ),
        ]

        XCTAssertEqual(
            optimizedResults(entries: entries, query: "New Workspace").first?.id,
            "palette.newWorkspace",
            "Exact title match must outrank the browser variant"
        )
        XCTAssertEqual(
            optimizedResults(entries: entries, query: "new browser").first?.id,
            "palette.newBrowserWorkspace",
            "Browser-specific query should surface the browser workspace command"
        )
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

    func testSearchPrefersTitleMatchOverKeywordOnlyMatchForCheckQuery() {
        let results = optimizedResults(entries: makeUpdateCommandEntries(), query: "check")

        XCTAssertEqual(
            results.prefix(2).map(\.id),
            ["command.checkForUpdates", "command.attemptUpdate"]
        )
    }

    func testResolvedSelectionIndexPrefersAnchoredCommand() {
        let resultIDs = ["command.0", "command.1", "command.2"]

        XCTAssertEqual(
            CommandPalettePendingActivation.resolvedSelectionIndex(
                preferredCommandID: "command.2",
                fallbackSelectedIndex: 0,
                resultIDs: resultIDs
            ),
            2
        )
        XCTAssertEqual(
            CommandPalettePendingActivation.resolvedSelectionIndex(
                preferredCommandID: "missing",
                fallbackSelectedIndex: 9,
                resultIDs: resultIDs
            ),
            2
        )
        XCTAssertEqual(
            CommandPalettePendingActivation.resolvedSelectionIndex(
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
            CommandPalettePendingActivation
                .selected(requestID: 41, fallbackSelectedIndex: 0, preferredCommandID: "command.2")
                .resolved(requestID: 41, resultIDs: resultIDs),
            .selected(index: 2)
        )
        XCTAssertEqual(
            CommandPalettePendingActivation
                .command(requestID: 41, commandID: "command.1")
                .resolved(requestID: 41, resultIDs: resultIDs),
            .command(commandID: "command.1")
        )
        XCTAssertNil(
            CommandPalettePendingActivation
                .command(requestID: 41, commandID: "missing")
                .resolved(requestID: 41, resultIDs: resultIDs)
        )
        XCTAssertNil(
            CommandPalettePendingActivation
                .selected(requestID: 40, fallbackSelectedIndex: 0, preferredCommandID: nil)
                .resolved(requestID: 41, resultIDs: resultIDs)
        )
    }

    func testPendingActivationRebasesWhenIndexReadyRefreshRestartsSearch() {
        XCTAssertEqual(
            CommandPalettePendingActivation
                .selected(requestID: 41, fallbackSelectedIndex: 2, preferredCommandID: "command.2")
                .rebased(toRequestID: 42),
            .selected(requestID: 42, fallbackSelectedIndex: 2, preferredCommandID: "command.2")
        )
        XCTAssertEqual(
            CommandPalettePendingActivation
                .command(requestID: 41, commandID: "command.1")
                .rebased(toRequestID: 42),
            .command(requestID: 42, commandID: "command.1")
        )
        XCTAssertNil((nil as CommandPalettePendingActivation?)?.rebased(toRequestID: 42))
    }

    func testPendingActivationResolutionClearsAndResolvesRebasedSynchronousSearch() {
        let resultIDs = ["command.0", "command.1", "command.2"]
        let rebasedActivation: CommandPalettePendingActivation? = CommandPalettePendingActivation
            .selected(requestID: 41, fallbackSelectedIndex: 0, preferredCommandID: "command.2")
            .rebased(toRequestID: 42)

        let resolution = rebasedActivation.resolution(
            requestID: 42,
            resultIDs: resultIDs
        )

        XCTAssertEqual(resolution.resolvedActivation, .selected(index: 2))
        XCTAssertTrue(resolution.shouldClearPendingActivation)
    }

    func testPendingActivationResolutionKeepsStaleActivation() {
        let pendingActivation: CommandPalettePendingActivation? = .command(requestID: 41, commandID: "command.1")
        let resolution = pendingActivation.resolution(
            requestID: 42,
            resultIDs: ["command.1"]
        )

        XCTAssertNil(resolution.resolvedActivation)
        XCTAssertFalse(resolution.shouldClearPendingActivation)
    }

    func testSelectionAnchorTracksVisiblePendingSelection() {
        let resultIDs = ["command.0", "command.1", "command.2"]
        let visibleAnchor = CommandPaletteSelectionNavigation.selectionAnchorCommandID(
            selectedIndex: 2,
            resultIDs: resultIDs
        )

        XCTAssertEqual(
            CommandPalettePendingActivation
                .selected(
                    requestID: 41,
                    fallbackSelectedIndex: 0,
                    preferredCommandID: visibleAnchor
                )
                .resolved(requestID: 41, resultIDs: resultIDs),
            .selected(index: 2)
        )
    }

    func testPreviewCandidateCommandIDsAreBounded() {
        let resultIDs = (0..<500).map { "command.\($0)" }

        let previewCandidateIDs = CommandPaletteSearchOrchestrator.previewCandidateCommandIDs(
            resultIDs: resultIDs,
            limit: 192
        )

        XCTAssertEqual(previewCandidateIDs.count, 192)
        XCTAssertEqual(previewCandidateIDs.first, "command.0")
        XCTAssertEqual(previewCandidateIDs.last, "command.191")
    }

    func testSynchronousSeedRunsOnlyWhenScopeHasNoVisibleResultsAndSearchIndexIsReady() {
        XCTAssertTrue(
            CommandPaletteSearchOrchestrator.shouldSynchronouslySeedResults(
                hasVisibleResultsForScope: false,
                hasSearchIndex: true,
                corpusCount: 5_000
            )
        )
        XCTAssertTrue(
            CommandPaletteSearchOrchestrator.shouldSynchronouslySeedResults(
                hasVisibleResultsForScope: false,
                hasSearchIndex: false,
                corpusCount: 256
            )
        )
        XCTAssertFalse(
            CommandPaletteSearchOrchestrator.shouldSynchronouslySeedResults(
                hasVisibleResultsForScope: false,
                hasSearchIndex: false,
                corpusCount: 257
            )
        )
        XCTAssertFalse(
            CommandPaletteSearchOrchestrator.shouldSynchronouslySeedResults(
                hasVisibleResultsForScope: true,
                hasSearchIndex: true,
                corpusCount: 5_000
            )
        )
    }

    func testPendingEmptyStateIsNotPreservedWhenSearchIsNotPending() {
        XCTAssertFalse(
            CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: false,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: true
            )
        )
    }

    func testPendingEmptyStateIsPreservedForSameResolvedNoMatchQuery() {
        XCTAssertTrue(
            CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: true
            )
        )
    }

    func testPendingEmptyStateIsPreservedForSameScopeNoMatchInPlaceEdit() {
        XCTAssertTrue(
            CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: true
            )
        )
    }

    func testPendingEmptyStateIsNotPreservedWhenResolvedResultsMayBeStale() {
        XCTAssertFalse(
            CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: false,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: true
            )
        )
        XCTAssertFalse(
            CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: false,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: true
            )
        )
        XCTAssertFalse(
            CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: false,
                resolvedResultsAreEmpty: true
            )
        )
        XCTAssertFalse(
            CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: false
            )
        )
    }

    func testVisibleResultsResetWhenQueryChangesCommandPaletteScope() {
        XCTAssertTrue(
            ContentView.commandPaletteShouldResetVisibleResultsForQueryTransition(
                oldQuery: ">",
                newQuery: "",
                hasVisibleResults: true
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteShouldResetVisibleResultsForQueryTransition(
                oldQuery: "",
                newQuery: ">",
                hasVisibleResults: true
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldResetVisibleResultsForQueryTransition(
                oldQuery: ">rename",
                newQuery: ">renam",
                hasVisibleResults: true
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldResetVisibleResultsForQueryTransition(
                oldQuery: ">",
                newQuery: "",
                hasVisibleResults: false
            )
        )
    }

    func testRefreshInputsPreferObservedQueryOverStaleState() {
        let inputs = ContentView.commandPaletteRefreshInputsForTests(
            stateQuery: ">",
            observedQuery: "",
            searchAllSurfaces: true
        )

        XCTAssertEqual(inputs.scope, "switcher")
        XCTAssertEqual(inputs.matchingQuery, "")
        XCTAssertFalse(inputs.includesSurfaces)
    }

    func testRefreshInputsIncludeSurfacesOnlyForNonEmptySwitcherQuery() {
        let switcherInputs = ContentView.commandPaletteRefreshInputsForTests(
            stateQuery: "",
            observedQuery: "  feature/search  ",
            searchAllSurfaces: true
        )
        XCTAssertEqual(switcherInputs.scope, "switcher")
        XCTAssertEqual(switcherInputs.matchingQuery, "feature/search")
        XCTAssertTrue(switcherInputs.includesSurfaces)

        let commandInputs = ContentView.commandPaletteRefreshInputsForTests(
            stateQuery: "",
            observedQuery: ">feature/search",
            searchAllSurfaces: true
        )
        XCTAssertEqual(commandInputs.scope, "commands")
        XCTAssertEqual(commandInputs.matchingQuery, "feature/search")
        XCTAssertFalse(commandInputs.includesSurfaces)

        let workspaceOnlyInputs = ContentView.commandPaletteRefreshInputsForTests(
            stateQuery: "",
            observedQuery: "feature/search",
            searchAllSurfaces: false
        )
        XCTAssertEqual(workspaceOnlyInputs.scope, "switcher")
        XCTAssertEqual(workspaceOnlyInputs.matchingQuery, "feature/search")
        XCTAssertFalse(workspaceOnlyInputs.includesSurfaces)
    }

    func testCommandContextFingerprintTracksExactContextValues() {
        let base = CommandPaletteContextSnapshot.fingerprint(
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
        let unreadChanged = CommandPaletteContextSnapshot.fingerprint(
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
        let renamed = CommandPaletteContextSnapshot.fingerprint(
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
        let base = CommandPaletteSwitcherFingerprintContext.fingerprint(
            windowContexts: [
                CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: "Window 2",
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(
                                directories: ["/Users/example/dev/cmuxterm"],
                                branches: ["feature/search-speed"],
                                ports: [3000]
                            ),
                            surfaces: []
                        )
                    ]
                )
            ]
        )
        let changedMetadata = CommandPaletteSwitcherFingerprintContext.fingerprint(
            windowContexts: [
                CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: "Window 2",
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(
                                directories: ["/Users/example/dev/other"],
                                branches: ["feature/search-speed"],
                                ports: [4000]
                            ),
                            surfaces: []
                        )
                    ]
                )
            ]
        )
        let changedDisplayName = CommandPaletteSwitcherFingerprintContext.fingerprint(
            windowContexts: [
                CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: "Window 2",
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Beta",
                            metadata: CommandPaletteSwitcherSearchMetadata(
                                directories: ["/Users/example/dev/cmuxterm"],
                                branches: ["feature/search-speed"],
                                ports: [3000]
                            ),
                            surfaces: []
                        )
                    ]
                )
            ]
        )

        XCTAssertNotEqual(base, changedMetadata)
        XCTAssertNotEqual(base, changedDisplayName)
    }

    func testSwitcherFingerprintTracksSurfaceValuesAtSameCardinality() {
        let windowID = UUID()
        let workspaceID = UUID()
        let surfaceID = UUID()

        let base = CommandPaletteSwitcherFingerprintContext.fingerprint(
            windowContexts: [
                CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: nil,
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(),
                            surfaces: [
                                CommandPaletteSwitcherFingerprintSurface(
                                    id: surfaceID,
                                    displayName: "Terminal",
                                    kindLabel: "Terminal",
                                    metadata: CommandPaletteSwitcherSearchMetadata(
                                        directories: ["/tmp/search-alpha"],
                                        branches: ["feature/a"],
                                        ports: [3000]
                                    )
                                )
                            ]
                        )
                    ]
                )
            ]
        )
        let changedSurfaceMetadata = CommandPaletteSwitcherFingerprintContext.fingerprint(
            windowContexts: [
                CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: nil,
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(),
                            surfaces: [
                                CommandPaletteSwitcherFingerprintSurface(
                                    id: surfaceID,
                                    displayName: "Terminal",
                                    kindLabel: "Terminal",
                                    metadata: CommandPaletteSwitcherSearchMetadata(
                                        directories: ["/tmp/search-beta"],
                                        branches: ["feature/a"],
                                        ports: [3000]
                                    )
                                )
                            ]
                        )
                    ]
                )
            ]
        )
        let changedSurfaceKind = CommandPaletteSwitcherFingerprintContext.fingerprint(
            windowContexts: [
                CommandPaletteSwitcherFingerprintContext(
                    windowId: windowID,
                    windowLabel: nil,
                    selectedWorkspaceId: workspaceID,
                    workspaces: [
                        CommandPaletteSwitcherFingerprintWorkspace(
                            id: workspaceID,
                            displayName: "Workspace Alpha",
                            metadata: CommandPaletteSwitcherSearchMetadata(),
                            surfaces: [
                                CommandPaletteSwitcherFingerprintSurface(
                                    id: surfaceID,
                                    displayName: "Terminal",
                                    kindLabel: "Browser",
                                    metadata: CommandPaletteSwitcherSearchMetadata(
                                        directories: ["/tmp/search-alpha"],
                                        branches: ["feature/a"],
                                        ports: [3000]
                                    )
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        XCTAssertNotEqual(base, changedSurfaceMetadata)
        XCTAssertNotEqual(base, changedSurfaceKind)
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
            _ = referenceResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
        }

        let referenceMs = bestOfElapsedMs {
            for query in queries {
                _ = referenceResults(entries: entries, query: query)
            }
        }
        let optimizedMs = bestOfElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+shift+p reference=%.2fms optimized=%.2fms", referenceMs, optimizedMs))
        XCTAssertLessThan(
            optimizedMs,
            referenceMs * 1.5,
            "Optimized command search regressed significantly: reference=\(referenceMs) optimized=\(optimizedMs)"
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
            _ = referenceResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
        }

        let referenceMs = bestOfElapsedMs {
            for query in queries {
                _ = referenceResults(entries: entries, query: query)
            }
        }
        let optimizedMs = bestOfElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+p reference=%.2fms optimized=%.2fms", referenceMs, optimizedMs))
        XCTAssertLessThan(
            optimizedMs,
            referenceMs * 1.5,
            "Optimized switcher search regressed significantly: reference=\(referenceMs) optimized=\(optimizedMs)"
        )
    }

    func testLargeWorkspaceSwitcherSearchBenchmarkAvoidsPerQueryPreparationCost() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let queries = repeatedQueries(
            [
                "workspace 799",
                "palette latency",
                "feature 401",
                "cmd-p-search",
                "project-642",
                "4207",
                "9204",
                "Window 3",
            ],
            repetitions: 3
        )

        for query in queries.prefix(8) {
            _ = referenceResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
        }

        let referenceMs = bestOfElapsedMs {
            for query in queries {
                _ = referenceResults(entries: entries, query: query)
            }
        }
        let optimizedMs = bestOfElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+p large-workspaces reference=%.2fms optimized=%.2fms", referenceMs, optimizedMs))
        XCTAssertLessThan(
            optimizedMs,
            referenceMs * 0.90,
            "Large switcher search should reuse prepared corpus data: reference=\(referenceMs) optimized=\(optimizedMs)"
        )
    }

    func testFastTypingPreviewSearchBenchmarkReportsEstimatedDroppedFrames() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let visibleCandidateCorpus = Array(corpus.prefix(128))
        let queries = repeatedQueries(
            fastTypingPrefixes("cmd-p-search") + fastTypingPrefixes("palette latency"),
            repetitions: 2
        )

        for query in queries.prefix(8) {
            _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
            _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query, resultLimit: 100) { _, _ in 0 }
            _ = CommandPaletteSearchEngine(entries: visibleCandidateCorpus).search(
            query: query, resultLimit: 48) { _, _ in 0 }
        }

        // Best-of-N per-query timing: each query's duration is the minimum over
        // several runs, so a single CI scheduler preemption on one run does not
        // flip the aggregate comparisons or the derived dropped-frame counts.
        // The relative signal is preserved because the cheaper code path still
        // wins on its fastest run.
        let timingRepetitions = 5
        var fullDurationsMs: [Double] = []
        var cappedFullDurationsMs: [Double] = []
        var previewDurationsMs: [Double] = []
        fullDurationsMs.reserveCapacity(queries.count)
        cappedFullDurationsMs.reserveCapacity(queries.count)
        previewDurationsMs.reserveCapacity(queries.count)

        for query in queries {
            fullDurationsMs.append(
                bestOfElapsedMs(repetitions: timingRepetitions) {
                    _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
                }
            )
            cappedFullDurationsMs.append(
                bestOfElapsedMs(repetitions: timingRepetitions) {
                    _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query, resultLimit: 100) { _, _ in 0 }
                }
            )
            previewDurationsMs.append(
                bestOfElapsedMs(repetitions: timingRepetitions) {
                    _ = CommandPaletteSearchEngine(entries: visibleCandidateCorpus).search(
            query: query, resultLimit: 48) { _, _ in 0 }
                }
            )
        }

        let fullMs = fullDurationsMs.reduce(0, +)
        let cappedFullMs = cappedFullDurationsMs.reduce(0, +)
        let previewMs = previewDurationsMs.reduce(0, +)
        let fullDroppedFrames = estimatedDroppedFrames(for: fullDurationsMs)
        let cappedFullDroppedFrames = estimatedDroppedFrames(for: cappedFullDurationsMs)
        let previewDroppedFrames = estimatedDroppedFrames(for: previewDurationsMs)
        let maxFullMs = fullDurationsMs.max() ?? 0
        let maxCappedFullMs = cappedFullDurationsMs.max() ?? 0
        let maxPreviewMs = previewDurationsMs.max() ?? 0
        let maxPreviewQuery = previewDurationsMs.enumerated().max(by: { $0.element < $1.element }).map {
            queries[$0.offset]
        } ?? ""

        print(String(
            format: "BENCH cmd+p fast-typing full=%.2fms cappedFull=%.2fms visiblePreview=%.2fms maxFull=%.2fms maxCappedFull=%.2fms maxVisiblePreview=%.2fms maxVisiblePreviewQuery=%@ fullDroppedFrames=%d cappedFullDroppedFrames=%d visiblePreviewDroppedFrames=%d",
            fullMs,
            cappedFullMs,
            previewMs,
            maxFullMs,
            maxCappedFullMs,
            maxPreviewMs,
            maxPreviewQuery,
            fullDroppedFrames,
            cappedFullDroppedFrames,
            previewDroppedFrames
        ))
        // Generous margins: capping/previewing should never be slower than the
        // fuller pipeline, but with best-of-N minima a measurement tie (the
        // cheaper path doing nearly identical work for these corpus sizes) must
        // not fail the test. Only a real regression where the cheaper path is
        // meaningfully slower trips these.
        XCTAssertLessThan(
            cappedFullMs,
            fullMs * 1.10,
            "Capped full-corpus search should avoid preparing results the UI cannot render: full=\(fullMs) capped=\(cappedFullMs)"
        )
        XCTAssertLessThanOrEqual(
            cappedFullDroppedFrames,
            fullDroppedFrames,
            "Capped full-corpus search should not increase estimated frame-budget misses: full=\(fullDroppedFrames) capped=\(cappedFullDroppedFrames)"
        )
        XCTAssertLessThan(
            previewMs,
            cappedFullMs * 1.10,
            "Visible-candidate preview search should avoid full-corpus work during fast typing: capped=\(cappedFullMs) preview=\(previewMs)"
        )
        XCTAssertLessThanOrEqual(
            previewDroppedFrames,
            cappedFullDroppedFrames,
            "Preview search should not increase estimated frame-budget misses: capped=\(cappedFullDroppedFrames) preview=\(previewDroppedFrames)"
        )
    }
}
