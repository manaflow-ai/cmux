import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class WorkspaceTeardownTests: XCTestCase {
    func testTeardownAllPanelsClearsPanelMetadataCaches() {
        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        workspace.setPanelCustomTitle(panelId: initialPanelId, title: "Initial custom title")
        workspace.setPanelPinned(panelId: initialPanelId, pinned: true)

        guard let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }

        workspace.setPanelCustomTitle(panelId: splitPanel.id, title: "Split custom title")
        workspace.setPanelPinned(panelId: splitPanel.id, pinned: true)
        workspace.markPanelUnread(initialPanelId)

        XCTAssertFalse(workspace.panels.isEmpty)
        XCTAssertFalse(workspace.panelTitles.isEmpty)
        XCTAssertFalse(workspace.panelCustomTitles.isEmpty)
        XCTAssertFalse(workspace.pinnedPanelIds.isEmpty)
        XCTAssertFalse(workspace.manualUnreadPanelIds.isEmpty)

        workspace.teardownAllPanels()

        XCTAssertTrue(workspace.panels.isEmpty)
        XCTAssertTrue(workspace.panelTitles.isEmpty)
        XCTAssertTrue(workspace.panelCustomTitles.isEmpty)
        XCTAssertTrue(workspace.pinnedPanelIds.isEmpty)
        XCTAssertTrue(workspace.manualUnreadPanelIds.isEmpty)
    }

    func testDisabledPortalRenderingDoesNotRestoreTerminalVisibility() throws {
#if DEBUG
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let terminalPanel = try XCTUnwrap(workspace.terminalPanel(for: panelId))

        terminalPanel.hostedView.setVisibleInUI(true)
        workspace.setPortalRenderingEnabled(false, reason: "test")
        XCTAssertFalse(terminalPanel.hostedView.debugPortalVisibleInUI)

        workspace.debugReconcileTerminalPortalVisibilityForTesting()
        XCTAssertFalse(terminalPanel.hostedView.debugPortalVisibleInUI)
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}


