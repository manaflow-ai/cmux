import CMUXMobileCore
import Foundation
@preconcurrency import Network
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Workspace list hash, capabilities & action gate
extension MobileHostAuthorizationTests {
    func testMobileWorkspaceListHashIncludesDisplayedDirectories() {
        let workspace = Workspace(
            title: "Mobile",
            workingDirectory: "/tmp/mobile-a",
            portOrdinal: 0
        )
        let initial = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        workspace.currentDirectory = "/tmp/mobile-b"
        let afterWorkspaceDirectory = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        XCTAssertNotEqual(initial, afterWorkspaceDirectory)

        workspace.panelDirectories[UUID()] = "/tmp/mobile-terminal"
        let afterTerminalDirectory = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        XCTAssertNotEqual(afterWorkspaceDirectory, afterTerminalDirectory)
    }

    func testMobileHostAdvertisesWorkspaceActionsCapability() {
        // The iOS client gates rename/pin on `workspace.actions.v1`; every
        // mobile.host.status path reads this single list, so advertising it here
        // is what makes the feature visible to a supporting Mac.
        let capabilities = MobileHostService.mobileHostCapabilities
        XCTAssertTrue(capabilities.contains("workspace.actions.v1"))
        XCTAssertTrue(capabilities.contains("terminal.render_grid.v1"))
    }

    // MARK: - Mobile workspace.action sub-action gate

    func testMobileWorkspaceActionGateAllowsOnlyPinUnpinRename() {
        for action in ["pin", "unpin", "rename", "PIN", "UnPin", "RENAME"] {
            XCTAssertTrue(
                TerminalController.mobileAllowsWorkspaceAction(action),
                "mobile workspace.action '\(action)' should be allowed"
            )
        }
        for action in [
            "move_up", "move-down", "move_top",
            "close_others", "close_above", "close_below",
            "set_color", "clear_color", "set_description", "clear_description",
            "clear_name", "mark_read", "mark_unread", "self_destruct", "",
        ] {
            XCTAssertFalse(
                TerminalController.mobileAllowsWorkspaceAction(action),
                "mobile workspace.action '\(action)' must be rejected"
            )
        }
        XCTAssertFalse(TerminalController.mobileAllowsWorkspaceAction(nil))
    }

}
