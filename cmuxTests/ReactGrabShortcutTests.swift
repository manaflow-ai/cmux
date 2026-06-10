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


// MARK: - React Grab shortcut routing and pasteback targets
final class ReactGrabShortcutRouteTests: XCTestCase {
    func testFocusedBrowserRoutesDirectlyWithoutPasteback() {
        let browserId = UUID()
        let terminalId = UUID()

        let route = resolveReactGrabShortcutRoute(
            panels: [
                ReactGrabShortcutPanelSnapshot(id: terminalId, panelType: .terminal, isFocused: false),
                ReactGrabShortcutPanelSnapshot(id: browserId, panelType: .browser, isFocused: true),
            ]
        )

        XCTAssertEqual(
            route,
            ReactGrabShortcutRoute(browserPanelId: browserId, returnTerminalPanelId: nil)
        )
    }

    func testFocusedTerminalRoutesToOnlyBrowserAndRemembersPastebackTarget() {
        let browserId = UUID()
        let terminalId = UUID()

        let route = resolveReactGrabShortcutRoute(
            panels: [
                ReactGrabShortcutPanelSnapshot(id: terminalId, panelType: .terminal, isFocused: true),
                ReactGrabShortcutPanelSnapshot(id: browserId, panelType: .browser, isFocused: false),
            ]
        )

        XCTAssertEqual(
            route,
            ReactGrabShortcutRoute(browserPanelId: browserId, returnTerminalPanelId: terminalId)
        )
    }

    func testFocusedTerminalDoesNotRouteWhenMultipleBrowsersExist() {
        let route = resolveReactGrabShortcutRoute(
            panels: [
                ReactGrabShortcutPanelSnapshot(id: UUID(), panelType: .terminal, isFocused: true),
                ReactGrabShortcutPanelSnapshot(id: UUID(), panelType: .browser, isFocused: false),
                ReactGrabShortcutPanelSnapshot(id: UUID(), panelType: .browser, isFocused: false),
            ]
        )

        XCTAssertNil(route)
    }

    func testFocusedTerminalDoesNotRouteWithoutBrowser() {
        let route = resolveReactGrabShortcutRoute(
            panels: [
                ReactGrabShortcutPanelSnapshot(id: UUID(), panelType: .terminal, isFocused: true),
            ]
        )

        XCTAssertNil(route)
    }
}


@MainActor
final class ReactGrabPastebackTargetTests: XCTestCase {
    func testPrefersExplicitTerminalTargetWhenBrowserPanelIsFocused() {
        let workspace = Workspace(title: "Tests")
        guard let terminalId = workspace.focusedPanelId else {
            XCTFail("Expected initial terminal panel")
            return
        }
        guard let browserPanel = workspace.newBrowserSplit(
            from: terminalId,
            orientation: .horizontal
        ) else {
            XCTFail("Expected browser split panel")
            return
        }

        workspace.focusPanel(browserPanel.id)

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)
        XCTAssertEqual(
            AppDelegate.resolveTerminalPanelForTextSend(
                in: workspace,
                preferredPanelId: terminalId
            )?.id,
            terminalId
        )
    }

    func testDoesNotFallbackWhenPreferredTerminalTargetIsMissing() {
        let workspace = Workspace(title: "Tests")
        guard let terminalId = workspace.focusedPanelId,
              let browserPanel = workspace.newBrowserSplit(
                from: terminalId,
                orientation: .horizontal
              ) else {
            XCTFail("Expected initial workspace split")
            return
        }

        workspace.focusPanel(browserPanel.id)

        XCTAssertNil(
            AppDelegate.resolveTerminalPanelForTextSend(
                in: workspace,
                preferredPanelId: UUID()
            )
        )
    }

    func testShortcutStillRoutesTerminalPastebackWhenWebViewFocusIsDeferred() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalId = workspace.focusedPanelId,
              let browserPanel = workspace.newBrowserSplit(
                from: terminalId,
                orientation: .horizontal
              ) else {
            XCTFail("Expected initial workspace with terminal and browser split")
            return
        }

        workspace.focusPanel(terminalId)

        XCTAssertTrue(manager.toggleReactGrabFromCurrentFocus())
        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)
        XCTAssertEqual(browserPanel.pendingReactGrabReturnTargetPanelId, terminalId)
    }

    func testShortcutClearsSplitZoomBeforeRoutingToBrowserPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalId = workspace.focusedPanelId,
              let browserPanel = workspace.newBrowserSplit(
                from: terminalId,
                orientation: .horizontal
              ) else {
            XCTFail("Expected initial workspace with terminal and browser split")
            return
        }

        workspace.focusPanel(terminalId)
        XCTAssertTrue(workspace.toggleSplitZoom(panelId: terminalId))
        XCTAssertTrue(workspace.bonsplitController.isSplitZoomed)

        XCTAssertTrue(manager.toggleReactGrabFromCurrentFocus())
        XCTAssertFalse(workspace.bonsplitController.isSplitZoomed)
        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)
        XCTAssertEqual(browserPanel.pendingReactGrabReturnTargetPanelId, terminalId)
    }
}


