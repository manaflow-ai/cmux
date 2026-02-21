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
                nextFocusedPanelId: nextFocusedPanelId,
                isManuallyUnread: true,
                markedAt: Date()
            )
        )
    }

    func testShouldNotClearManualUnreadWhenFocusStaysOnSamePanelWithinGrace() {
        let panelId = UUID()
        let now = Date()

        XCTAssertFalse(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: panelId,
                nextFocusedPanelId: panelId,
                isManuallyUnread: true,
                markedAt: now.addingTimeInterval(-0.05),
                now: now,
                sameTabGraceInterval: 0.2
            )
        )
    }

    func testShouldClearManualUnreadWhenFocusStaysOnSamePanelAfterGrace() {
        let panelId = UUID()
        let now = Date()

        XCTAssertTrue(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: panelId,
                nextFocusedPanelId: panelId,
                isManuallyUnread: true,
                markedAt: now.addingTimeInterval(-0.25),
                now: now,
                sameTabGraceInterval: 0.2
            )
        )
    }

    func testShouldNotClearManualUnreadWhenNotManuallyUnread() {
        XCTAssertFalse(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: UUID(),
                nextFocusedPanelId: UUID(),
                isManuallyUnread: false,
                markedAt: Date()
            )
        )
    }

    func testShouldNotClearManualUnreadWhenNoPreviousFocusAndWithinGrace() {
        let now = Date()

        XCTAssertFalse(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: nil,
                nextFocusedPanelId: UUID(),
                isManuallyUnread: true,
                markedAt: now.addingTimeInterval(-0.05),
                now: now,
                sameTabGraceInterval: 0.2
            )
        )
    }

    func testShouldShowUnreadIndicatorWhenNotificationIsUnread() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: true,
                isManuallyUnread: false
            )
        )
    }

    func testShouldShowUnreadIndicatorWhenManualUnreadIsSet() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                isManuallyUnread: true
            )
        )
    }

    func testShouldHideUnreadIndicatorWhenNeitherNotificationNorManualUnreadExists() {
        XCTAssertFalse(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                isManuallyUnread: false
            )
        )
    }
}
