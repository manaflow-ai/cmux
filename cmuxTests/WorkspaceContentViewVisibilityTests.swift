import XCTest
import CoreGraphics
import CMUXLayout

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceContentViewVisibilityTests: XCTestCase {
    func testCanvasResizeHitAreaUsesLargeTwoAxisCorners() {
        let hitArea = CanvasResizeHitArea(
            cardSize: CGSize(width: 320, height: 220),
            edgeHitSize: 16,
            cornerHitSize: 44
        )

        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 4, y: 4)), .topLeft)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 316, y: 4)), .topRight)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 4, y: 216)), .bottomLeft)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 316, y: 216)), .bottomRight)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 32, y: 32)), .topLeft)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 288, y: 188)), .bottomRight)
    }

    func testCanvasResizeHitAreaKeepsCenterInteractive() {
        let hitArea = CanvasResizeHitArea(
            cardSize: CGSize(width: 320, height: 220),
            edgeHitSize: 16,
            cornerHitSize: 44
        )

        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 8, y: 110)), .left)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 312, y: 110)), .right)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 160, y: 8)), .top)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 160, y: 212)), .bottom)
        XCTAssertNil(hitArea.handle(at: CGPoint(x: 160, y: 110)))
        XCTAssertNil(hitArea.handle(at: CGPoint(x: 60, y: 60)))
    }

    func testNonSelectedNonRetiringWorkspaceIsFullyHidden() {
        XCTAssertEqual(
            MountedWorkspacePresentationPolicy.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: false
            ),
            MountedWorkspacePresentation(
                isRenderedVisible: false,
                isPanelVisible: false,
                renderOpacity: 0
            )
        )
    }

    func testRetiringWorkspaceKeepsShellMountedButStopsPanelRendering() {
        XCTAssertEqual(
            MountedWorkspacePresentationPolicy.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: true
            ),
            MountedWorkspacePresentation(
                isRenderedVisible: true,
                isPanelVisible: false,
                renderOpacity: 0
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

    func testPanelVisibleInUIReturnsFalseForFocusedDeselectedPanel() {
        XCTAssertFalse(
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
        let snapshot = PaneLayoutSnapshot(
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
            CGRect(x: 677.5, y: 28, width: 500, height: 292)
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

        let snapshot = PaneLayoutSnapshot(
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
            [CGRect(x: 677.5, y: 28, width: 500, height: 292)]
        )
    }
}
