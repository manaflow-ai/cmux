import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceManualUnreadTests: XCTestCase {
    func testShouldClearManualUnreadWhenFocusMovesToDifferentPanel() {
        let previousFocusedPanelId = UUID()
        let nextFocusedPanelId = UUID()

        XCTAssertTrue(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: previousFocusedPanelId,
                nextFocusedPanelId: nextFocusedPanelId
            )
        )
    }

    func testShouldNotClearManualUnreadWhenFocusStaysOnSamePanel() {
        let panelId = UUID()

        XCTAssertFalse(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: panelId,
                nextFocusedPanelId: panelId
            )
        )
    }

    func testShouldNotClearManualUnreadWhenNoPanelWasPreviouslyFocused() {
        XCTAssertFalse(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: nil,
                nextFocusedPanelId: UUID()
            )
        )
    }
}
