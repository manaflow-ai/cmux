import Bonsplit
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FocusedPanelFlashShortcutTests {
    @Test("Explicit focused-panel flashes survive a competing unread indicator")
    func explicitFocusedPanelFlashesSurviveCompetingUnreadIndicator() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = originalAppDelegate ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let notificationStore = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)
        let originalPaneFlashEnabled = defaults.object(forKey: NotificationPaneFlashSettings.enabledKey)
        var registeredWindowID: UUID?

        defer {
            if let registeredWindowID {
                appDelegate.unregisterMainWindowContextForTesting(windowId: registeredWindowID)
            }
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            AppDelegate.shared = originalAppDelegate
            restoreDefault(originalExperimentEnabled, key: TmuxOverlayExperimentSettings.enabledKey)
            restoreDefault(originalExperimentTarget, key: TmuxOverlayExperimentSettings.targetKey)
            restoreDefault(originalPaneFlashEnabled, key: NotificationPaneFlashSettings.enabledKey)
        }

        let manager = TabManager()
        registeredWindowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = notificationStore
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)
        defaults.set(true, forKey: NotificationPaneFlashSettings.enabledKey)

        let workspace = try #require(manager.selectedWorkspace)
        let unreadPanelID = try #require(workspace.focusedPanelId)
        let focusedPanel = try #require(
            workspace.newTerminalSplit(from: unreadPanelID, orientation: .horizontal)
        )
        #expect(workspace.focusedPanelId == focusedPanel.id)

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: unreadPanelID,
            title: "Unread",
            subtitle: "",
            body: "Another panel owns notification attention"
        )
        #expect(
            notificationStore.hasVisibleNotificationIndicator(
                forTabId: workspace.id,
                surfaceId: unreadPanelID
            )
        )

        let flashTokenBeforeShortcut = workspace.tmuxWorkspaceFlashToken
        manager.triggerFocusFlash()

        #expect(workspace.tmuxWorkspaceFlashToken == flashTokenBeforeShortcut + 1)
        #expect(workspace.tmuxWorkspaceFlashPanelId == focusedPanel.id)

        let flashTokenBeforeSocket = workspace.tmuxWorkspaceFlashToken
        let windowID = try #require(registeredWindowID)
        let socketFlash = TerminalController.shared.controlSurfaceTriggerFlash(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: true,
                windowID: windowID,
                groupID: nil,
                workspaceID: workspace.id,
                surfaceID: focusedPanel.id,
                paneID: nil
            ),
            surfaceID: focusedPanel.id
        )

        guard case .flashed(_, let workspaceID, let surfaceID) = socketFlash else {
            Issue.record("Socket flash did not resolve the focused panel: \(socketFlash)")
            return
        }
        #expect(workspaceID == workspace.id)
        #expect(surfaceID == focusedPanel.id)
        #expect(workspace.tmuxWorkspaceFlashToken == flashTokenBeforeSocket + 1)
        #expect(workspace.tmuxWorkspaceFlashPanelId == focusedPanel.id)
    }

    @Test("User-initiated flashes use the notification ring accent")
    func userInitiatedFlashUsesNotificationRingAccent() {
        #expect(
            WorkspaceAttentionCoordinator.flashStyle(for: .userInitiated).accent ==
                WorkspaceAttentionCoordinator.notificationRingStyle.accent
        )
    }

    private func restoreDefault(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
