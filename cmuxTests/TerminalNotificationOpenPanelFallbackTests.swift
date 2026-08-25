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
    func notificationForMovedSurfaceStaysInOriginatingWindow() throws {
        _ = NSApplication.shared
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let store = TerminalNotificationStore.shared
        let previousNotificationStore = appDelegate.notificationStore
        let managerA = TabManager()
        let managerB = TabManager()
        let originWindowId = UUID()
        let destinationWindowId = UUID()
        let originWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let destinationWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        originWindow.isReleasedWhenClosed = false
        destinationWindow.isReleasedWhenClosed = false
        originWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(originWindowId.uuidString)")
        destinationWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(destinationWindowId.uuidString)")

        AppDelegate.shared = appDelegate
        appDelegate.notificationStore = store
        let originWorkspace = managerA.addWorkspace(title: "Origin", select: true)
        let destinationWorkspace = managerB.addWorkspace(title: "Destination", select: true)
        let originPanelId = try #require(originWorkspace.focusedPanelId)
        appDelegate.registerMainWindow(
            originWindow,
            windowId: originWindowId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        appDelegate.registerMainWindow(
            destinationWindow,
            windowId: destinationWindowId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: originWindowId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: destinationWindowId)
            originWindow.close()
            destinationWindow.close()
            for workspace in managerA.tabs { managerA.closeWorkspace(workspace) }
            for workspace in managerB.tabs { managerB.closeWorkspace(workspace) }
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = previousNotificationStore
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousShared
        }

        let transfer = try #require(originWorkspace.detachSurface(panelId: originPanelId))
        let destinationPaneId = try #require(destinationWorkspace.bonsplitController.allPaneIds.first)
        _ = try #require(destinationWorkspace.attachDetachedSurface(transfer, inPane: destinationPaneId, focus: false))
        managerA.selectTab(originWorkspace)
        managerB.selectTab(destinationWorkspace)
        destinationWindow.makeKeyAndOrderFront(nil)

        let notification = TerminalNotification(
            id: UUID(),
            tabId: originWorkspace.id,
            surfaceId: originPanelId,
            title: "Moved surface",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 1_778_888_890),
            isRead: false
        )

        #expect(appDelegate.notificationNavigation.openNotification(
            notification.notificationNavigationSnapshot,
            preferredWindowId: originWindowId
        ))
        #expect(managerA.selectedTabId == originWorkspace.id)
        #expect(managerB.selectedTabId == destinationWorkspace.id)
    }

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
        // AppKit defaults to isReleasedWhenClosed, so the close() below would release a
        // window ARC still owns and the over-release lands in a later autorelease pool drain.
        window.isReleasedWhenClosed = false
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

    @Test
    func confinedNotificationWithMovedSurfaceOpensAuthorizedWorkspace() throws {
        let store = TerminalNotificationStore.shared
        let previousShared = AppDelegate.shared
        let appDelegate = previousShared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        store.replaceNotificationsForTesting([])

        let authorizedWorkspace = manager.addWorkspace(title: "Authorized", select: true)
        let liveWorkspace = manager.addWorkspace(title: "Live owner", select: false)
        let movedPanelId = try #require(authorizedWorkspace.focusedPanelId)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // AppKit defaults to isReleasedWhenClosed, so the close() below would release a
        // window ARC still owns and the over-release lands in a later autorelease pool drain.
        window.isReleasedWhenClosed = false
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
            AppDelegate.shared = previousShared
        }

        let notification = TerminalNotification(
            id: UUID(),
            tabId: authorizedWorkspace.id,
            surfaceId: movedPanelId,
            retargetsToLiveSurfaceOwner: false,
            title: "Confined notification",
            subtitle: "Completed",
            body: "Stay in the authorized workspace",
            createdAt: Date(timeIntervalSince1970: 1_778_888_889),
            isRead: false
        )
        store.replaceNotificationsForTesting([notification])

        let transfer = try #require(authorizedWorkspace.detachSurface(panelId: movedPanelId))
        let destinationPaneId = try #require(liveWorkspace.bonsplitController.allPaneIds.first)
        _ = try #require(liveWorkspace.attachDetachedSurface(transfer, inPane: destinationPaneId, focus: false))
        manager.selectTab(liveWorkspace)

        #expect(appDelegate.openTerminalNotification(notification))
        #expect(manager.selectedTabId == authorizedWorkspace.id)
        #expect(manager.focusedSurfaceId(for: authorizedWorkspace.id) != movedPanelId)
        #expect(store.notifications.first(where: { $0.id == notification.id })?.isRead == true)
    }
}
