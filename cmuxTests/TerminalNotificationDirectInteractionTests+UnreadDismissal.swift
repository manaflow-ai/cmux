import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Unread dismissal on direct interaction
extension TerminalNotificationDirectInteractionTests {
    func testTerminalMouseDownDismissesUnreadWhenSurfaceIsAlreadyFirstResponder() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let window = makeWindow()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            window.orderOut(nil)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected an initial focused terminal panel")
            return
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hostedView = terminalPanel.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        guard let surfaceView = surfaceView(in: hostedView) else {
            XCTFail("Expected terminal surface view")
            return
        }

        GhosttySurfaceScrollView.resetFlashCounts()
        AppFocusState.overrideIsFocused = true
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))

        AppFocusState.overrideIsFocused = true
        let pointInWindow = surfaceView.convert(NSPoint(x: 20, y: 20), to: nil)
        let event = makeMouseEvent(type: .leftMouseDown, location: pointInWindow, window: window)
        surfaceView.mouseDown(with: event)
        drainMainQueue()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))
        XCTAssertEqual(GhosttySurfaceScrollView.flashCount(for: terminalPanel.id), 1)
    }

    func testTerminalKeyDownDismissesUnreadWhenSurfaceIsAlreadyFirstResponder() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let window = makeWindow()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            window.orderOut(nil)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected an initial focused terminal panel")
            return
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hostedView = terminalPanel.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }

        GhosttySurfaceScrollView.resetFlashCounts()
        AppFocusState.overrideIsFocused = true
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))

        let event = makeKeyEvent(characters: "", keyCode: 122, window: window)
        surfaceView.keyDown(with: event)
        drainMainQueue()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))
        XCTAssertEqual(GhosttySurfaceScrollView.flashCount(for: terminalPanel.id), 1)
    }

}
