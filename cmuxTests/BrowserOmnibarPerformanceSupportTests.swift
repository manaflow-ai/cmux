import XCTest
import CmuxBrowser
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

        await waitForPendingSleep(on: clock)
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
        await waitForPendingSleep(on: clock)
        scheduler.cancelPendingRefresh()
        await clock.advance()
        await Task.yield()
        await Task.yield()

        listener.cancel()

        XCTAssertEqual(refreshCount, 0)
    }

    @MainActor
    func testSuggestionRefreshSchedulerInvalidatesQueuedRefreshOnCancel() async {
        let clock = ManualOmnibarSuggestionRefreshClock()
        let scheduler = OmnibarSuggestionRefreshScheduler(
            debounceDelay: .milliseconds(40),
            clock: clock
        )
        let staleRefresh = expectation(description: "queued refresh emitted")
        var shouldProcessQueuedRefresh: Bool?

        scheduler.scheduleRefresh()
        await waitForPendingSleep(on: clock)
        await clock.advance()
        await Task.yield()
        await Task.yield()

        scheduler.cancelPendingRefresh()

        let listener = Task { @MainActor in
            var iterator = scheduler.refreshStream.makeAsyncIterator()
            guard let generation = await iterator.next() else { return }
            shouldProcessQueuedRefresh = scheduler.shouldProcessRefresh(generation)
            staleRefresh.fulfill()
        }

        await fulfillment(of: [staleRefresh], timeout: 1)
        listener.cancel()

        XCTAssertEqual(
            shouldProcessQueuedRefresh,
            false,
            "A refresh already queued before cancellation should not run after Escape, hide, or focus loss."
        )
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

        let effects = state.reduce(.bufferChanged("go"))

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

        let effects = state.reduce(.bufferChanged("go"))

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

        let effects = state.reduce(.escape)

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

    @MainActor
    private func waitForPendingSleep(on clock: ManualOmnibarSuggestionRefreshClock) async {
        let pendingSleep = expectation(description: "manual clock has a pending sleep")
        let waiter = Task { @MainActor in
            await clock.waitForPendingSleep()
            pendingSleep.fulfill()
        }
        await fulfillment(of: [pendingSleep], timeout: 1)
        waiter.cancel()
    }
}

private actor ManualOmnibarSuggestionRefreshClock: OmnibarSuggestionRefreshClock {
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingSleepWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                resumePendingSleepWaiters()
            }
        } onCancel: {
            Task {
                await self.cancel(id)
            }
        }
    }

    func waitForPendingSleep() async {
        guard continuations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            pendingSleepWaiters.append(continuation)
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

    private func resumePendingSleepWaiters() {
        let waiters = pendingSleepWaiters
        pendingSleepWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
