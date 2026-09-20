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

        XCTAssertEqual(panel.loadingHeadline, "Creating a workspace on early-plum-alpaca…")
        panel.resetLoading()
        XCTAssertNil(panel.loadingHeadline)
    }
}
