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
final class WorkspaceAttentionFlashTests: XCTestCase {
    func testMoveFocusDoesNotTriggerWholePaneFlashTokenWhenWholePaneModeEnabled() {
        let defaults = UserDefaults.standard
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        defer {
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 0)
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)

        workspace.moveFocus(direction: .left)

        XCTAssertEqual(workspace.focusedPanelId, leftPanelId)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            0,
            "Expected moving focus left to avoid any workspace-pane flash"
        )
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)

        workspace.moveFocus(direction: .right)

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            0,
            "Expected moving focus right to avoid any workspace-pane flash"
        )
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)
    }

    func testMoveFocusSuppressesWorkspacePaneFlashWhenAnotherPaneOwnsUnreadAttention() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let notificationStore = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = notificationStore
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        workspace.moveFocus(direction: .left)

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: leftPanelId,
            title: "Unread",
            subtitle: "",
            body: "Left pane owns notification attention"
        )

        XCTAssertTrue(
            notificationStore.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: leftPanelId),
            "Expected the left pane to own visible notification attention before moving focus"
        )

        let flashTokenBeforeNavigation = workspace.tmuxWorkspaceFlashToken

        workspace.moveFocus(direction: .right)

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            flashTokenBeforeNavigation,
            "Expected navigation flash to be suppressed while another pane owns notification attention"
        )
    }
}


