import Bonsplit
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
    @Test("Cmd-Shift-H flashes the focused panel when another panel is unread")
    func explicitFocusedPanelFlashSurvivesCompetingUnreadIndicator() throws {
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

        defer {
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
