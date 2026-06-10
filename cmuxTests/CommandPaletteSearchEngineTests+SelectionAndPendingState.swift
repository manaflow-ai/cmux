import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Selection anchoring, pending activation, and refresh state
extension CommandPaletteSearchEngineTests {
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

    func testPendingActivationRebasesWhenIndexReadyRefreshRestartsSearch() {
        XCTAssertEqual(
            ContentView.commandPalettePendingActivation(
                .selected(requestID: 41, fallbackSelectedIndex: 2, preferredCommandID: "command.2"),
                rebasedTo: 42
            ),
            .selected(requestID: 42, fallbackSelectedIndex: 2, preferredCommandID: "command.2")
        )
        XCTAssertEqual(
            ContentView.commandPalettePendingActivation(
                .command(requestID: 41, commandID: "command.1"),
                rebasedTo: 42
            ),
            .command(requestID: 42, commandID: "command.1")
        )
        XCTAssertNil(ContentView.commandPalettePendingActivation(nil, rebasedTo: 42))
    }

    func testPendingActivationResolutionClearsAndResolvesRebasedSynchronousSearch() {
        let resultIDs = ["command.0", "command.1", "command.2"]
        let rebasedActivation = ContentView.commandPalettePendingActivation(
            .selected(requestID: 41, fallbackSelectedIndex: 0, preferredCommandID: "command.2"),
            rebasedTo: 42
        )

        let resolution = ContentView.commandPalettePendingActivationResolution(
            rebasedActivation,
            requestID: 42,
            resultIDs: resultIDs
        )

        XCTAssertEqual(resolution.resolvedActivation, .selected(index: 2))
        XCTAssertTrue(resolution.shouldClearPendingActivation)
    }

    func testPendingActivationResolutionKeepsStaleActivation() {
        let resolution = ContentView.commandPalettePendingActivationResolution(
            .command(requestID: 41, commandID: "command.1"),
            requestID: 42,
            resultIDs: ["command.1"]
        )

        XCTAssertNil(resolution.resolvedActivation)
        XCTAssertFalse(resolution.shouldClearPendingActivation)
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

}
