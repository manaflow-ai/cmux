import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Sparkle
import CmuxUpdater

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Main window focus controller right sidebar hide
final class MainWindowFocusControllerRightSidebarHideTests: XCTestCase {
    private final class TestRightSidebarResponder: NSView, FeedKeyboardFocusResponder {
        override var acceptsFirstResponder: Bool { true }
    }

    @MainActor
    func testHiddenRightSidebarClearsFocusIntentWhenNoTerminalCanRestore() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState()
        )
        let workspaceId = UUID()
        let panelId = UUID()

        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
        controller.noteRightSidebarInteraction(mode: .feed)
        XCTAssertFalse(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))

        XCTAssertFalse(controller.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded())
        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
    }

    @MainActor
    func testHiddenRightSidebarDoesNotRestoreWhenTerminalAlreadyOwnsFocus() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState()
        )
        let workspaceId = UUID()
        let panelId = UUID()

        controller.noteTerminalInteraction(workspaceId: workspaceId, panelId: panelId)

        XCTAssertFalse(controller.shouldRestoreTerminalFocusWhenRightSidebarHides(currentResponder: nil))
        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
    }

    @MainActor
    func testMainPanelInteractionKeepsFeedSelectionInactive() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState()
        )
        let itemId = UUID()
        let workspaceId = UUID()
        let panelId = UUID()

        XCTAssertTrue(controller.selectFeedItem(itemId, focusFeed: false))
        XCTAssertEqual(controller.feedFocusSnapshot().selectedItemId, itemId)
        XCTAssertTrue(controller.feedFocusSnapshot().isKeyboardActive)

        controller.noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)

        XCTAssertEqual(controller.feedFocusSnapshot().selectedItemId, itemId)
        XCTAssertFalse(controller.feedFocusSnapshot().isKeyboardActive)
        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
        XCTAssertEqual(controller.focusToggleDestination(), .rightSidebar)
    }

    @MainActor
    func testFocusShortcutToggleUsesActualRightSidebarResponderOverStaleIntent() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState()
        )
        let responder = TestRightSidebarResponder(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

        let workspaceId = UUID()
        let panelId = UUID()
        controller.noteTerminalInteraction(workspaceId: workspaceId, panelId: panelId)

        XCTAssertEqual(controller.focusToggleDestination(currentResponder: responder), .terminal)
        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
    }

    @MainActor
    func testPendingSessionsFocusSurvivesStaleFeedResponderDuringModeSwitch() {
        let fileExplorerState = FileExplorerState()
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: fileExplorerState
        )
        let staleFeedResponder = TestRightSidebarResponder(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

        XCTAssertTrue(controller.selectFeedItem(UUID(), focusFeed: false))
        XCTAssertTrue(controller.focusRightSidebar(mode: .sessions, focusFirstItem: true))
        XCTAssertEqual(controller.intent, .rightSidebar(mode: .sessions))
        XCTAssertEqual(fileExplorerState.mode, .sessions)
        XCTAssertEqual(controller.debugPendingRightSidebarFocusMode, .sessions)

        controller.debugSyncAfterResponderChange(responder: staleFeedResponder)

        XCTAssertEqual(controller.intent, .rightSidebar(mode: .sessions))
        XCTAssertEqual(controller.debugPendingRightSidebarFocusMode, .sessions)
    }

    @MainActor
    func testPendingSessionsFocusCompletesWhenRightSidebarHostRegisters() {
        let fileExplorerState = FileExplorerState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = contentView
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: window,
            tabManager: TabManager(),
            fileExplorerState: fileExplorerState
        )

        XCTAssertTrue(controller.focusRightSidebar(mode: .sessions, focusFirstItem: true))
        XCTAssertEqual(controller.debugPendingRightSidebarFocusMode, .sessions)

        let focusHost = RightSidebarKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        defer {
            _ = window.makeFirstResponder(nil)
            focusHost.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }
        contentView.addSubview(focusHost)
        controller.registerRightSidebarHost(focusHost)

        XCTAssertNil(controller.debugPendingRightSidebarFocusMode)
        XCTAssertTrue(window.firstResponder === focusHost)
    }

    @MainActor
    func testFocusShortcutToggleClearsRightSidebarIntentWhenTerminalIsUnavailable() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState()
        )
        let workspaceId = UUID()
        let panelId = UUID()

        controller.noteRightSidebarInteraction(mode: .feed)
        XCTAssertFalse(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))

        XCTAssertFalse(controller.toggleRightSidebarOrTerminalFocus())
        XCTAssertTrue(controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId))
    }
}

