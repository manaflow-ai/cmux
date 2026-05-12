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
}
