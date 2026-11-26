import AppKit
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Owns the live window and focused routing context required by shortcut tests.
/// The app's menu and shortcut paths intentionally resolve through the shared
/// AppDelegate, so a windowless model fixture cannot exercise those paths.
@MainActor
final class NewCloudWorkspaceShortcutWindowFixture {
    let appDelegate: AppDelegate
    let tabManager: TabManager
    let windowID: UUID
    let window: NSWindow
    private let originalAppDelegate: AppDelegate?

    init() {
        originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        appDelegate.mainWindowContexts.values.first { $0.windowId == windowID }?.window = window
        window.makeKeyAndOrderFront(nil)
        appDelegate.debugSetShortcutRoutingFocusedWindowForTesting(window)
        self.appDelegate = appDelegate
        self.tabManager = tabManager
        self.windowID = windowID
        self.window = window
    }

    func cleanup() {
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: true)
        tabManager.tabs.forEach { $0.teardownAllPanels() }
        appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
        window.orderOut(nil)
        window.close()
        AppDelegate.shared = originalAppDelegate
    }
}
