import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Search pipeline parity, result limits, and preview corpus
extension CommandPaletteSearchEngineTests {
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

        let matches = CommandPaletteSearchOrchestrator.resolvedSearchMatches(
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

        let matches = CommandPaletteSearchOrchestrator.resolvedSearchMatches(
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
        let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus)

        let previewCommandIDs = CommandPaletteSearchOrchestrator.commandPreviewMatchCommandIDsForTests(
            searchCorpus: corpus,
            searchIndex: searchIndex,
            candidateCommandIDs: ["command.find"],
            searchCorpusByID: corpusByID,
            query: "finde",
            resultLimit: 48
        )

        XCTAssertEqual(previewCommandIDs.first, "command.finder")
    }

}
