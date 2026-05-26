import XCTest
import CoreGraphics
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceContentViewVisibilityTests: XCTestCase {
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

    func testRetiringWorkspaceStaysPanelVisibleDuringHandoff() {
        XCTAssertEqual(
            MountedWorkspacePresentationPolicy.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: true
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

@MainActor
final class WorkspacePageLifecycleTests: XCTestCase {
    func testSwitchingPagesPreservesLivePanelIdentityAcrossDetachAndReattach() throws {
        let workspace = Workspace()
        let firstPageId = workspace.activePageId
        let firstPaneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)

        XCTAssertNotNil(workspace.newTerminalSurface(inPane: firstPaneId, focus: false))
        let firstPagePanelIds = Set(workspace.panels.keys)
        XCTAssertEqual(firstPagePanelIds.count, 2)

        let secondPage = workspace.newPage(select: true)
        XCTAssertEqual(workspace.activePageId, secondPage.id)

        let secondPagePanelIds = Set(workspace.panels.keys)
        XCTAssertEqual(
            secondPagePanelIds.count,
            1,
            "A fresh page should mount its own placeholder terminal"
        )
        XCTAssertNotEqual(firstPagePanelIds, secondPagePanelIds)

        workspace.selectPage(firstPageId)
        XCTAssertEqual(workspace.activePageId, firstPageId)
        XCTAssertEqual(
            Set(workspace.panels.keys),
            firstPagePanelIds,
            "Returning to the first page should reattach the parked live panels"
        )

        workspace.selectPage(secondPage.id)
        XCTAssertEqual(workspace.activePageId, secondPage.id)
        XCTAssertEqual(
            Set(workspace.panels.keys),
            secondPagePanelIds,
            "Returning to the second page should reuse its parked live panel instead of rebuilding a new one"
        )
    }

    func testRuntimePageRestoreReplacesPreviousPagePaneSkeleton() throws {
        let workspace = Workspace()
        let firstPageId = workspace.activePageId
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertNotNil(workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal))
        let firstPagePanelIds = Set(workspace.panels.keys)
        let firstPagePaneCount = workspace.bonsplitController.allPaneIds.count
        XCTAssertEqual(firstPagePaneCount, 2)

        let secondPage = workspace.newPage(select: true)
        let secondPanelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertNotNil(workspace.newTerminalSplit(from: secondPanelId, orientation: .vertical))
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)

        workspace.selectPage(firstPageId)

        XCTAssertEqual(workspace.activePageId, firstPageId)
        XCTAssertEqual(Set(workspace.panels.keys), firstPagePanelIds)
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            firstPagePaneCount,
            "Runtime page restore should replace the leaving page's empty pane skeleton"
        )
        XCTAssertNotEqual(workspace.activePageId, secondPage.id)
    }
}
