import XCTest
import Testing
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

@Suite(.serialized)
@MainActor
struct WorkspacePageLifecycleTests {
    @Test func switchingPagesPreservesLivePanelIdentityAcrossDetachAndReattach() throws {
        let workspace = Workspace()
        let firstPageId = workspace.activePageId
        let firstPaneId = try #require(workspace.bonsplitController.allPaneIds.first)

        #expect(workspace.newTerminalSurface(inPane: firstPaneId, focus: false) != nil)
        let firstPagePanelIds = Set(workspace.panels.keys)
        #expect(firstPagePanelIds.count == 2)

        let secondPage = workspace.newPage(select: true)
        #expect(workspace.activePageId == secondPage.id)

        let secondPagePanelIds = Set(workspace.panels.keys)
        #expect(secondPagePanelIds.count == 1, "A fresh page should mount its own placeholder terminal")
        #expect(firstPagePanelIds != secondPagePanelIds)

        workspace.selectPage(firstPageId)
        #expect(workspace.activePageId == firstPageId)
        #expect(
            Set(workspace.panels.keys) == firstPagePanelIds,
            "Returning to the first page should reattach the parked live panels"
        )

        workspace.selectPage(secondPage.id)
        #expect(workspace.activePageId == secondPage.id)
        #expect(
            Set(workspace.panels.keys) == secondPagePanelIds,
            "Returning to the second page should reuse its parked live panel instead of rebuilding a new one"
        )
    }

    @Test func runtimePageRestoreReplacesPreviousPagePaneSkeleton() throws {
        let workspace = Workspace()
        let firstPageId = workspace.activePageId
        let firstPanelId = try #require(workspace.focusedPanelId)
        #expect(workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal) != nil)
        let firstPagePanelIds = Set(workspace.panels.keys)
        let firstPagePaneCount = workspace.bonsplitController.allPaneIds.count
        #expect(firstPagePaneCount == 2)

        let secondPage = workspace.newPage(select: true)
        let secondPanelId = try #require(workspace.focusedPanelId)
        #expect(workspace.newTerminalSplit(from: secondPanelId, orientation: .vertical) != nil)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)

        workspace.selectPage(firstPageId)

        #expect(workspace.activePageId == firstPageId)
        #expect(Set(workspace.panels.keys) == firstPagePanelIds)
        #expect(
            workspace.bonsplitController.allPaneIds.count == firstPagePaneCount,
            "Runtime page restore should replace the leaving page's empty pane skeleton"
        )
        #expect(workspace.activePageId != secondPage.id)
    }

    @Test func runtimePageRestoreDoesNotRecordPlaceholderPanelsAsClosedItems() throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let workspace = Workspace()
        let firstPageId = workspace.activePageId
        let firstPanelId = try #require(workspace.focusedPanelId)
        #expect(workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal) != nil)

        let secondPage = workspace.newPage(select: true)
        let secondPanelId = try #require(workspace.focusedPanelId)
        #expect(workspace.newTerminalSplit(from: secondPanelId, orientation: .vertical) != nil)

        workspace.selectPage(firstPageId)
        workspace.selectPage(secondPage.id)

        #expect(
            !ClosedItemHistoryStore.shared.canReopen,
            "Runtime page restore should not expose synthetic placeholder panels in recently closed items"
        )
    }

    @Test func runtimePageRestoreFallsBackWhenSelectedPanelDidNotAttach() {
        let missingSelectedPanelId = UUID()
        let attachedPanelId = UUID()

        #expect(
            Workspace.runtimePageRestoreSelectedPanelId(
                snapshotSelectedPanelId: missingSelectedPanelId,
                attachedPanelIds: [attachedPanelId]
            ) == attachedPanelId,
            "Runtime page restore should select an attached fallback panel when the stored selected panel failed to attach"
        )
    }
}
