import XCTest
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserOmnibarPerformanceSupportTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testSuggestionRefreshSchedulerCoalescesTypingBurst() {
        let scheduler = OmnibarSuggestionRefreshScheduler(debounceDelay: .milliseconds(40))
        let firstRefresh = expectation(description: "first debounced refresh emitted")
        let noExtraRefresh = expectation(description: "no extra refresh emitted")
        noExtraRefresh.isInverted = true
        var refreshCount = 0

        scheduler.refreshPublisher
            .sink {
                refreshCount += 1
                if refreshCount == 1 {
                    firstRefresh.fulfill()
                } else {
                    noExtraRefresh.fulfill()
                }
            }
            .store(in: &cancellables)

        for _ in 0..<20 {
            scheduler.scheduleRefresh()
        }

        wait(for: [firstRefresh, noExtraRefresh], timeout: 0.3)

        XCTAssertEqual(
            refreshCount,
            1,
            "A burst of omnibar text changes should schedule one suggestion refresh after the debounce window."
        )
    }

    func testSuggestionRefreshSchedulerCancelsPendingRefresh() {
        let scheduler = OmnibarSuggestionRefreshScheduler(debounceDelay: .milliseconds(40))
        let noRefresh = expectation(description: "no refresh after cancellation")
        noRefresh.isInverted = true
        var refreshCount = 0

        scheduler.refreshPublisher
            .sink {
                refreshCount += 1
                noRefresh.fulfill()
            }
            .store(in: &cancellables)

        scheduler.scheduleRefresh()
        scheduler.cancelPendingRefresh()

        wait(for: [noRefresh], timeout: 0.2)

        XCTAssertEqual(refreshCount, 0)
    }

    func testOmnibarBufferChangeClearsInlineCompletionBeforeDebouncedRefresh() {
        var state = OmnibarState(
            isFocused: true,
            currentURLString: "",
            buffer: "g",
            suggestions: [],
            selectedSuggestionIndex: 0,
            selectedSuggestionID: nil,
            isUserEditing: true
        )

        let effects = omnibarReduce(state: &state, event: .bufferChanged("go"))

        XCTAssertTrue(effects.shouldRefreshSuggestions)
        XCTAssertTrue(effects.shouldClearInlineCompletion)
    }

    func testOmnibarUnchangedBufferKeepsInlineCompletionStable() {
        var state = OmnibarState(
            isFocused: true,
            currentURLString: "",
            buffer: "go",
            suggestions: [],
            selectedSuggestionIndex: 0,
            selectedSuggestionID: nil,
            isUserEditing: true
        )

        let effects = omnibarReduce(state: &state, event: .bufferChanged("go"))

        XCTAssertTrue(effects.shouldRefreshSuggestions)
        XCTAssertFalse(effects.shouldClearInlineCompletion)
    }

    func testOmnibarEscapeCancelsPendingSuggestionRefresh() {
        var state = OmnibarState(
            isFocused: true,
            currentURLString: "",
            buffer: "go",
            suggestions: [],
            selectedSuggestionIndex: 0,
            selectedSuggestionID: nil,
            isUserEditing: true
        )

        let effects = omnibarReduce(state: &state, event: .escape)

        XCTAssertTrue(effects.shouldSelectAll)
        XCTAssertTrue(effects.shouldCancelPendingSuggestionRefresh)
        XCTAssertEqual(state.buffer, "")
        XCTAssertFalse(state.isUserEditing)
    }

    func testOpenTabSuggestionSeedSnapshotsAreEvaluatedOnlyOnce() {
        let workspaceId = UUID()
        let panelId = UUID()
        let snapshot = BrowserOpenTabSuggestionSnapshot(
            workspaceId: workspaceId,
            panelId: panelId,
            url: "https://example.com/docs",
            title: "Example Docs"
        )
        XCTAssertNotNil(snapshot)

        let index = BrowserOpenTabSuggestionIndex()
        var seedCallCount = 0

        func matches(for query: String) -> [OmnibarOpenTabMatch] {
            index.matching(
                for: query,
                currentWorkspaceId: UUID(),
                currentPanelId: UUID(),
                currentPanelSnapshot: nil,
                includeCurrentPanelForSingleCharacterQuery: false,
                limit: 5,
                seedSnapshots: {
                    seedCallCount += 1
                    return [snapshot!]
                }
            )
        }

        XCTAssertEqual(matches(for: "example").map(\.url), ["https://example.com/docs"])
        XCTAssertEqual(matches(for: "docs").map(\.url), ["https://example.com/docs"])
        XCTAssertEqual(seedCallCount, 1)
    }

    func testNonMatchingCurrentSnapshotDoesNotDedupeIndexedMatch() {
        let workspaceId = UUID()
        let panelId = UUID()
        let url = "https://example.com/"
        let currentSnapshot = BrowserOpenTabSuggestionSnapshot(
            workspaceId: workspaceId,
            panelId: panelId,
            url: url,
            title: nil
        )
        let indexedSnapshot = BrowserOpenTabSuggestionSnapshot(
            workspaceId: workspaceId,
            panelId: panelId,
            url: url,
            title: "Docs"
        )
        XCTAssertNotNil(currentSnapshot)
        XCTAssertNotNil(indexedSnapshot)

        let index = BrowserOpenTabSuggestionIndex()
        let matches = index.matching(
            for: "d",
            currentWorkspaceId: workspaceId,
            currentPanelId: panelId,
            currentPanelSnapshot: currentSnapshot,
            includeCurrentPanelForSingleCharacterQuery: true,
            limit: 5,
            seedSnapshots: { [indexedSnapshot!] }
        )

        XCTAssertEqual(matches.map(\.title), ["Docs"])
        XCTAssertEqual(matches.map(\.url), [url])
    }
}
