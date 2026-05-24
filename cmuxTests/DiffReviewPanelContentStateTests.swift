import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class DiffReviewPanelContentStateTests: XCTestCase {
    func testFailedPhaseTakesPriorityOverStaleSnapshot() {
        let snapshot = DiffReviewSnapshot(
            repositoryRoot: "/repo",
            currentBranch: "main",
            branches: ["main"],
            selectedTarget: .workingTree,
            files: [],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let state = DiffReviewPanelContentState.resolve(
            directory: "/repo",
            snapshot: snapshot,
            phase: .failed("Could not apply reverse patch")
        )

        XCTAssertEqual(state, .error("Could not apply reverse patch"))
    }

    func testOnlyLoadedPhaseAllowsLiveRefresh() {
        XCTAssertFalse(DiffReviewLoadPhase.idle.allowsLiveRefresh)
        XCTAssertFalse(DiffReviewLoadPhase.loading.allowsLiveRefresh)
        XCTAssertTrue(DiffReviewLoadPhase.loaded.allowsLiveRefresh)
        XCTAssertFalse(DiffReviewLoadPhase.failed("Could not apply reverse patch").allowsLiveRefresh)
    }

    func testSummaryFormatterSubstitutesLocalizedPlaceholders() {
        let snapshot = DiffReviewSnapshot(
            repositoryRoot: "/repo",
            currentBranch: "main",
            branches: ["main"],
            selectedTarget: .workingTree,
            files: [
                DiffReviewFile(
                    id: "Sources/App.swift",
                    path: "Sources/App.swift",
                    oldPath: nil,
                    status: .modified,
                    hunks: [],
                    addedLineCount: 0,
                    deletedLineCount: 0
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let summary = DiffReviewSummaryFormatter.summaryText(snapshot: snapshot)

        XCTAssertFalse(summary.contains("%"))
        XCTAssertTrue(summary.contains("1"))
        XCTAssertTrue(summary.contains("main"))
    }

    @MainActor
    func testStopObservingClearsCancelledInitialLoadingState() {
        let store = DiffReviewStore()

        store.setDirectory("/repo")
        XCTAssertTrue(store.isLoading)

        store.stopObserving()

        XCTAssertFalse(store.isLoading)
    }
}
