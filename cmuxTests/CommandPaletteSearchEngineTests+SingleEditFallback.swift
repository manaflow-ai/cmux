import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Nucleo Swift single-edit fallback and typo tolerance
extension CommandPaletteSearchEngineTests {
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

        let matches = CommandPaletteSearchOrchestrator.resolvedSearchMatches(
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

        let matches = CommandPaletteSearchOrchestrator.resolvedSearchMatches(
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

        let matches = CommandPaletteSearchOrchestrator.resolvedSearchMatches(
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

    func testSwiftFallbackMergeKeepsCombinedResultsSortedByScore() {
        let entries = [
            FixtureEntry(
                id: "palette.high",
                rank: 0,
                title: "High Score",
                searchableTexts: ["High Score"]
            ),
            FixtureEntry(
                id: "palette.medium",
                rank: 1,
                title: "Medium Score",
                searchableTexts: ["Medium Score"]
            ),
            FixtureEntry(
                id: "palette.fallback",
                rank: 2,
                title: "Fallback Score",
                searchableTexts: ["Fallback Score"]
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

        let matches = CommandPaletteSearchOrchestrator.mergedSwiftFallbackMatchesForTests(
            [
                CommandPaletteResolvedSearchMatch(
                    commandID: "palette.fallback",
                    score: 25,
                    titleMatchIndices: []
                )
            ],
            nucleoMatches: [
                CommandPaletteResolvedSearchMatch(
                    commandID: "palette.medium",
                    score: 80,
                    titleMatchIndices: []
                ),
                CommandPaletteResolvedSearchMatch(
                    commandID: "palette.high",
                    score: 100,
                    titleMatchIndices: []
                ),
            ],
            searchCorpusByID: corpusByID,
            limit: 3
        )

        XCTAssertEqual(matches.map(\.commandID), ["palette.high", "palette.medium", "palette.fallback"])
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
        let matches = CommandPaletteSearchOrchestrator.resolvedSearchMatches(
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

}
