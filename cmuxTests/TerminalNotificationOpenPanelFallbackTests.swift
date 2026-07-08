import AppKit
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
struct TerminalNotificationOpenPanelFallbackTests {
    @Test
    func notificationOpenUsesStoredPanelWhenSurfaceIsStale() throws {
        let store = TerminalNotificationStore.shared
        let previousShared = AppDelegate.shared
        let appDelegate = previousShared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false
        store.replaceNotificationsForTesting([])

        let sourceWorkspace = manager.addWorkspace(title: "Source", select: true)
        let targetWorkspace = manager.addWorkspace(title: "Open Panel Target", select: false)
        let targetPanelId = try #require(targetWorkspace.focusedPanelId)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        window.makeKeyAndOrderFront(nil)

        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
            for workspace in manager.tabs {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            AppDelegate.shared = previousShared
        }

        let notification = TerminalNotification(
            id: UUID(),
            tabId: targetWorkspace.id,
            surfaceId: UUID(),
            panelId: targetPanelId,
            title: "Open Stale Surface",
            subtitle: "socket-test",
            body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_888_888),
            isRead: false
        )
        store.replaceNotificationsForTesting([notification])
        manager.selectTab(sourceWorkspace)

        let resolution = TerminalController.shared.controlNotificationOpen(id: notification.id)
        guard case .opened(let snapshot) = resolution else {
            Issue.record("Expected notification.open to open stale surface via stored panel, got \(resolution)")
            return
        }

        #expect(snapshot.workspaceID == targetWorkspace.id)
        #expect(snapshot.surfaceID == targetPanelId)
        #expect(snapshot.isRead)
        #expect(manager.selectedTabId == targetWorkspace.id)
        #expect(manager.focusedSurfaceId(for: targetWorkspace.id) == targetPanelId)
        #expect(store.notifications.first(where: { $0.id == notification.id })?.isRead == true)
    }
}
