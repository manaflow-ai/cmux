import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudVMLoadingPanelTests: XCTestCase {
    func testCloudWorkspaceLoadingHeadlineReplacesBaseProgressCopyAndResets() {
        let panel = CloudVMLoadingPanel(workspaceId: UUID())
        panel.configureLoadingHeadline("Creating a workspace on early-plum-alpaca…")

        guard case .loading(let headline) = panel.phase else {
            return XCTFail("headline configuration must remain in the loading phase")
        }
        XCTAssertEqual(headline, "Creating a workspace on early-plum-alpaca…")
        panel.resetLoading()
        guard case .loading(let resetHeadline) = panel.phase else {
            return XCTFail("reset must return to loading")
        }
        XCTAssertNil(resetHeadline)
    }

    func testFailureReplacesLoadingHeadlineAndShowsFailurePhase() {
        let panel = CloudVMLoadingPanel(workspaceId: UUID())
        panel.configureLoadingHeadline("Creating a workspace on early-plum-alpaca…")

        panel.showFailure("The Cloud VM service is unavailable")

        XCTAssertTrue(panel.hasFailed)
        XCTAssertFalse(panel.isLoading)
        guard case .failed(let message, _) = panel.phase else {
            return XCTFail("failure must be the sole presentation phase")
        }
        XCTAssertEqual(message, "The Cloud VM service is unavailable")
    }
}
