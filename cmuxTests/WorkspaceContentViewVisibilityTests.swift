import XCTest
import CoreGraphics
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceContentViewVisibilityTests: XCTestCase {
    func testBackgroundPrimedWorkspaceStaysMountedButNotPanelVisible() {
        XCTAssertEqual(
            MountedWorkspacePresentationPolicy.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: false,
                shouldPrimeInBackground: true
            ),
            MountedWorkspacePresentation(
                isRenderedVisible: false,
                isPanelVisible: false,
                renderOpacity: 0.001
            )
        )
    }

    func testRetiringWorkspaceStaysPanelVisibleDuringHandoff() {
        XCTAssertEqual(
            MountedWorkspacePresentationPolicy.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: true,
                shouldPrimeInBackground: false
            ),
            MountedWorkspacePresentation(
                isRenderedVisible: true,
                isPanelVisible: true,
                renderOpacity: 1
            )
        )
    }

    func testPanelVisibleInUIReturnsFalseWhenWorkspaceHidden() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: false,
                isSelectedInPane: true,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForSelectedPanel() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: true,
                isFocused: false
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForFocusedPanelDuringTransientSelectionGap() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsFalseWhenNeitherSelectedNorFocused() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: false
            )
        )
    }

    func testTmuxWorkspacePaneOverlayRectReturnsMatchingPaneFrame() {
        let paneID = PaneID(id: UUID())
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: paneID.id.uuidString,
                    frame: PixelRect(x: 877.5, y: 32, width: 500, height: 320),
                    selectedTabId: nil,
                    tabIds: []
                )
            ],
            focusedPaneId: paneID.id.uuidString,
            timestamp: 0
        )

        XCTAssertEqual(
            WorkspaceContentView.tmuxWorkspacePaneOverlayRect(
                layoutSnapshot: snapshot,
                paneId: paneID
            ),
            CGRect(x: 677.5, y: 30, width: 500, height: 290)
        )
    }

    func testTmuxWorkspacePaneTabBarRectReturnsTopChromeFrame() {
        let paneID = PaneID(id: UUID())
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: paneID.id.uuidString,
                    frame: PixelRect(x: 877.5, y: 32, width: 500, height: 320),
                    selectedTabId: nil,
                    tabIds: []
                )
            ],
            focusedPaneId: paneID.id.uuidString,
            timestamp: 0
        )

        XCTAssertEqual(
            WorkspaceContentView.tmuxWorkspacePaneTabBarRect(
                layoutSnapshot: snapshot,
                paneId: paneID
            ),
            CGRect(x: 677.5, y: 0, width: 500, height: 30)
        )
    }

    func testInactiveBonsplitTabBarRectsExcludeFocusedPaneWhenWorkspaceInputActive() {
        let focusedPaneID = PaneID(id: UUID())
        let unfocusedPaneID = PaneID(id: UUID())
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: focusedPaneID.id.uuidString,
                    frame: PixelRect(x: 200, y: 32, width: 500, height: 320),
                    selectedTabId: nil,
                    tabIds: []
                ),
                PaneGeometry(
                    paneId: unfocusedPaneID.id.uuidString,
                    frame: PixelRect(x: 700, y: 32, width: 500, height: 320),
                    selectedTabId: nil,
                    tabIds: []
                )
            ],
            focusedPaneId: focusedPaneID.id.uuidString,
            timestamp: 0
        )

        XCTAssertEqual(
            WorkspaceContentView.inactiveBonsplitTabBarRects(
                layoutSnapshot: snapshot,
                focusedPaneId: focusedPaneID,
                zoomedPaneId: nil,
                isWorkspaceInputActive: true,
                shouldDimInactivePanes: true
            ),
            [CGRect(x: 500, y: 0, width: 500, height: 30)]
        )
    }

    func testInactiveBonsplitTabBarRectsIncludeOnlyZoomedPaneWhenWorkspaceInactive() {
        let firstPaneID = PaneID(id: UUID())
        let zoomedPaneID = PaneID(id: UUID())
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: firstPaneID.id.uuidString,
                    frame: PixelRect(x: 200, y: 32, width: 500, height: 320),
                    selectedTabId: nil,
                    tabIds: []
                ),
                PaneGeometry(
                    paneId: zoomedPaneID.id.uuidString,
                    frame: PixelRect(x: 700, y: 32, width: 500, height: 320),
                    selectedTabId: nil,
                    tabIds: []
                )
            ],
            focusedPaneId: firstPaneID.id.uuidString,
            timestamp: 0
        )

        XCTAssertEqual(
            WorkspaceContentView.inactiveBonsplitTabBarRects(
                layoutSnapshot: snapshot,
                focusedPaneId: firstPaneID,
                zoomedPaneId: zoomedPaneID,
                isWorkspaceInputActive: false,
                shouldDimInactivePanes: true
            ),
            [CGRect(x: 500, y: 0, width: 500, height: 30)]
        )
    }

    @MainActor
    func testTmuxWorkspacePaneUnreadRectsIncludeFocusedReadIndicator() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let surfaceId = workspace.surfaceIdFromPanelId(panelId),
              let paneId = workspace.paneId(forPanelId: panelId) else {
            XCTFail("Expected selected workspace geometry")
            return
        }

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: paneId.id.uuidString,
                    frame: PixelRect(x: 877.5, y: 32, width: 500, height: 320),
                    selectedTabId: surfaceId.uuid.uuidString,
                    tabIds: [surfaceId.uuid.uuidString]
                )
            ],
            focusedPaneId: paneId.id.uuidString,
            timestamp: 0
        )

        XCTAssertEqual(
            WorkspaceContentView.tmuxWorkspacePaneUnreadRects(
                workspace: workspace,
                notificationStore: store,
                layoutSnapshot: snapshot
            ),
            [CGRect(x: 677.5, y: 30, width: 500, height: 290)]
        )
    }
}
