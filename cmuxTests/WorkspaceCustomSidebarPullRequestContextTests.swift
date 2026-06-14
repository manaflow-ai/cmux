import XCTest
import CmuxSwiftRender

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceCustomSidebarPullRequestContextTests: XCTestCase {
    @MainActor
    func testValuesIncludePanelPullRequestWhenFocusedPanelMirrorIsNil() throws {
        let workspace = Workspace(
            title: "Tests",
            workingDirectory: FileManager.default.currentDirectoryPath,
            portOrdinal: 0
        )
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 5314,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/5314")!,
            status: .open
        )
        // The focused-panel `pullRequest` mirror only refreshes while its panel
        // is focused, so live sessions routinely hold panel pull requests with a
        // nil mirror. The interpreter context must project from the per-panel
        // state, not the mirror.
        workspace.pullRequest = nil

        let values = workspace.customSidebarPullRequestValues()
        XCTAssertEqual(values.count, 1)
        guard case .object(let fields)? = values.first else {
            XCTFail("Expected object pull-request value, got \(String(describing: values.first))")
            return
        }
        XCTAssertEqual(fields["number"], .int(5314))
        XCTAssertEqual(fields["status"], .string("open"))
        XCTAssertEqual(fields["url"], .string("https://github.com/manaflow-ai/cmux/pull/5314"))
        XCTAssertEqual(fields["stale"], .bool(false))
    }

    @MainActor
    func testValuesEmptyWhenWorkspaceHasNoPullRequests() {
        let workspace = Workspace(
            title: "Tests",
            workingDirectory: FileManager.default.currentDirectoryPath,
            portOrdinal: 0
        )

        XCTAssertEqual(workspace.customSidebarPullRequestValues(), [])
    }
}
