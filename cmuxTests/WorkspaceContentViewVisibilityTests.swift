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

    func testHandoffCompletionWaitsForSelectedWorkspaceVisibleSignalWhenWorkspaceIsReady() {
        let selectedWorkspaceId = UUID()
        let otherWorkspaceId = UUID()

        XCTAssertTrue(
            WorkspaceHandoffCompletionPolicy.shouldComplete(
                signal: .selectedWorkspaceVisible,
                selectedWorkspaceId: selectedWorkspaceId,
                signalWorkspaceId: selectedWorkspaceId,
                hasRetiringWorkspace: true,
                selectedWorkspaceReady: true
            )
        )
        XCTAssertFalse(
            WorkspaceHandoffCompletionPolicy.shouldComplete(
                signal: .selectedWorkspaceVisible,
                selectedWorkspaceId: selectedWorkspaceId,
                signalWorkspaceId: selectedWorkspaceId,
                hasRetiringWorkspace: true,
                selectedWorkspaceReady: false
            )
        )
        XCTAssertFalse(
            WorkspaceHandoffCompletionPolicy.shouldComplete(
                signal: .selectedWorkspaceVisible,
                selectedWorkspaceId: selectedWorkspaceId,
                signalWorkspaceId: otherWorkspaceId,
                hasRetiringWorkspace: true,
                selectedWorkspaceReady: true
            )
        )
    }

    func testHandoffCompletionConsumesAlreadyVisibleSelectedWorkspaceAfterReadinessChanges() {
        let selectedWorkspaceId = UUID()
        let otherWorkspaceId = UUID()

        XCTAssertFalse(
            WorkspaceHandoffCompletionPolicy.shouldCompleteFromAlreadyVisibleSelectedWorkspace(
                selectedWorkspaceId: selectedWorkspaceId,
                visibleWorkspaceIds: [selectedWorkspaceId],
                hasRetiringWorkspace: true,
                selectedWorkspaceReady: false
            )
        )
        XCTAssertTrue(
            WorkspaceHandoffCompletionPolicy.shouldCompleteFromAlreadyVisibleSelectedWorkspace(
                selectedWorkspaceId: selectedWorkspaceId,
                visibleWorkspaceIds: [selectedWorkspaceId, otherWorkspaceId],
                hasRetiringWorkspace: true,
                selectedWorkspaceReady: true
            )
        )
        XCTAssertFalse(
            WorkspaceHandoffCompletionPolicy.shouldCompleteFromAlreadyVisibleSelectedWorkspace(
                selectedWorkspaceId: selectedWorkspaceId,
                visibleWorkspaceIds: [otherWorkspaceId],
                hasRetiringWorkspace: true,
                selectedWorkspaceReady: true
            )
        )
        XCTAssertFalse(
            WorkspaceHandoffCompletionPolicy.shouldCompleteFromAlreadyVisibleSelectedWorkspace(
                selectedWorkspaceId: selectedWorkspaceId,
                visibleWorkspaceIds: [selectedWorkspaceId],
                hasRetiringWorkspace: false,
                selectedWorkspaceReady: true
            )
        )
    }

    func testVisibilityCommitStateClearsHiddenWorkspaceBeforeAlreadyVisibleHandoff() {
        let selectedWorkspaceId = UUID()
        var visibleWorkspaceIds: Set<UUID> = []

        WorkspaceVisibilityCommitState.updateVisibleWorkspaceIds(
            &visibleWorkspaceIds,
            workspaceId: selectedWorkspaceId,
            isVisible: true
        )
        XCTAssertTrue(visibleWorkspaceIds.contains(selectedWorkspaceId))

        WorkspaceVisibilityCommitState.updateVisibleWorkspaceIds(
            &visibleWorkspaceIds,
            workspaceId: selectedWorkspaceId,
            isVisible: false
        )
        XCTAssertFalse(visibleWorkspaceIds.contains(selectedWorkspaceId))
        XCTAssertFalse(
            WorkspaceHandoffCompletionPolicy.shouldCompleteFromAlreadyVisibleSelectedWorkspace(
                selectedWorkspaceId: selectedWorkspaceId,
                visibleWorkspaceIds: visibleWorkspaceIds,
                hasRetiringWorkspace: true,
                selectedWorkspaceReady: true
            )
        )
    }

    func testHandoffCompletionRequiresRetiringWorkspaceForFocus() {
        let selectedWorkspaceId = UUID()

        XCTAssertFalse(
            WorkspaceHandoffCompletionPolicy.shouldComplete(
                signal: .selectedWorkspaceFocus,
                selectedWorkspaceId: selectedWorkspaceId,
                signalWorkspaceId: selectedWorkspaceId,
                hasRetiringWorkspace: false,
                selectedWorkspaceReady: true
            )
        )
    }

    func testHandoffCompletionAcceptsSelectedFocusSignal() {
        let selectedWorkspaceId = UUID()

        XCTAssertTrue(
            WorkspaceHandoffCompletionPolicy.shouldComplete(
                signal: .selectedWorkspaceFocus,
                selectedWorkspaceId: selectedWorkspaceId,
                signalWorkspaceId: selectedWorkspaceId,
                hasRetiringWorkspace: true,
                selectedWorkspaceReady: false
            )
        )
        XCTAssertFalse(
            WorkspaceHandoffCompletionPolicy.shouldComplete(
                signal: .selectedWorkspaceFocus,
                selectedWorkspaceId: selectedWorkspaceId,
                signalWorkspaceId: UUID(),
                hasRetiringWorkspace: true,
                selectedWorkspaceReady: false
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
