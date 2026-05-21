#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension TabManager {
    func teardownAllWorkspacesForTesting(notificationStore: TerminalNotificationStore?) {
        for workspace in Array(tabs) {
            notificationStore?.clearNotifications(forTabId: workspace.id)
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }
        if let firstWorkspace = tabs.first,
           selectedTabId == nil || !tabs.contains(where: { $0.id == selectedTabId }) {
            selectedTabId = firstWorkspace.id
        }
    }
}
