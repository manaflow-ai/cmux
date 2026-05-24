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

    func testSummaryFormatterUsesSelectedBranchForBranchComparison() {
        let snapshot = DiffReviewSnapshot(
            repositoryRoot: "/repo",
            currentBranch: "feature",
            branches: ["main", "feature"],
            selectedTarget: .branch("main"),
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

        XCTAssertTrue(summary.contains("main"))
        XCTAssertFalse(summary.contains("feature"))
    }

    func testSummaryFormatterUsesSingularFileLabel() {
        let snapshot = DiffReviewSnapshot(
            repositoryRoot: "/repo",
            currentBranch: nil,
            branches: [],
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

        XCTAssertTrue(summary.contains("1 file"))
        XCTAssertFalse(summary.contains("1 files"))
    }

    func testSummaryFormatterUsesPluralFileLabelForZeroFiles() {
        let snapshot = DiffReviewSnapshot(
            repositoryRoot: "/repo",
            currentBranch: nil,
            branches: [],
            selectedTarget: .workingTree,
            files: [],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let summary = DiffReviewSummaryFormatter.summaryText(snapshot: snapshot)

        XCTAssertTrue(summary.contains("0 files"))
    }

    func testSummaryFormatterUsesPluralFileLabelForMultipleFiles() {
        let snapshot = DiffReviewSnapshot(
            repositoryRoot: "/repo",
            currentBranch: nil,
            branches: [],
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
                ),
                DiffReviewFile(
                    id: "Sources/Model.swift",
                    path: "Sources/Model.swift",
                    oldPath: nil,
                    status: .added,
                    hunks: [],
                    addedLineCount: 0,
                    deletedLineCount: 0
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let summary = DiffReviewSummaryFormatter.summaryText(snapshot: snapshot)

        XCTAssertTrue(summary.contains("2 files"))
    }

    func testGitFailureMessagesAreActionSpecificAndSanitized() {
        let revertMessage = DiffReviewGitError.commandFailed(.hunkRevertFailed).localizedDescription
        let diffMessage = DiffReviewGitError.commandFailed(.diffUnavailable).localizedDescription

        XCTAssertTrue(revertMessage.contains("Refresh"))
        XCTAssertTrue(diffMessage.contains("comparison"))
        XCTAssertFalse(revertMessage.contains("patch failed"))
        XCTAssertFalse(diffMessage.contains("fatal:"))
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
