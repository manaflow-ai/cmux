import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserOmnibarPerformanceSupportTests: XCTestCase {
    @MainActor
    func testSuggestionRefreshSchedulerCoalescesTypingBurst() async {
        let clock = ManualOmnibarSuggestionRefreshClock()
        let scheduler = OmnibarSuggestionRefreshScheduler(
            debounceDelay: .milliseconds(40),
            clock: clock
        )
        let firstRefresh = expectation(description: "first debounced refresh emitted")
        var refreshCount = 0

        let listener = Task { @MainActor in
            for await _ in scheduler.refreshStream {
                refreshCount += 1
                if refreshCount == 1 {
                    firstRefresh.fulfill()
                }
            }
        }

        for _ in 0..<20 {
            scheduler.scheduleRefresh()
        }

        await Task.yield()
        await clock.advance()
        await fulfillment(of: [firstRefresh], timeout: 1)
        await Task.yield()
        listener.cancel()

        XCTAssertEqual(
            refreshCount,
            1,
            "A burst of omnibar text changes should schedule one suggestion refresh after the debounce window."
        )
    }

    @MainActor
    func testSuggestionRefreshSchedulerCancelsPendingRefresh() async {
        let clock = ManualOmnibarSuggestionRefreshClock()
        let scheduler = OmnibarSuggestionRefreshScheduler(
            debounceDelay: .milliseconds(40),
            clock: clock
        )
        var refreshCount = 0

        let listener = Task { @MainActor in
            for await _ in scheduler.refreshStream {
                refreshCount += 1
            }
        }

        scheduler.scheduleRefresh()
        await Task.yield()
        scheduler.cancelPendingRefresh()
        await clock.advance()
        await Task.yield()
        await Task.yield()

        listener.cancel()

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

private actor ManualOmnibarSuggestionRefreshClock: OmnibarSuggestionRefreshClock {
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
            }
        } onCancel: {
            Task {
                await self.cancel(id)
            }
        }
    }

    func advance() {
        let pendingContinuations = Array(continuations.values)
        continuations.removeAll(keepingCapacity: true)
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
