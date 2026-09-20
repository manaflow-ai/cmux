import AppKit
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Supplies an authenticated account for tests that exercise the Cloud menu gate.
///
/// ``AppDelegate`` owns the auth composition, so setting only the Cloud feature
/// flag is insufficient: the production menu gate also requires an authenticated
/// account on ``AppDelegate.shared``. The fixture uses the existing deterministic
/// UI-test auth path and an isolated defaults suite; it never contacts Stack Auth.
@MainActor
final class NewCloudWorkspaceShortcutAuthFixture {
    struct MainWindow {
        let id: UUID
        let window: NSWindow
        let tabManager: TabManager
    }

    private let defaults: UserDefaults
    private let suiteName: String
    private let originalAppDelegate: AppDelegate?
    private var registeredMainWindows: [(appDelegate: AppDelegate, mainWindow: MainWindow)] = []
    let composition: MacAuthComposition

    init() {
        originalAppDelegate = AppDelegate.shared
        suiteName = "NewCloudWorkspaceShortcutTests.Auth.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        composition = MacAuthComposition(
            environment: [
                "CMUX_UITEST_AUTH_FIXTURE": "1",
                "CMUX_UITEST_AUTH_USER_ID": "new-cloud-workspace-test-user"
            ],
            defaults: defaults
        )
    }

    func makeAppDelegate(authenticated: Bool = true) -> AppDelegate {
        let appDelegate = AppDelegate()
        if authenticated {
            appDelegate.auth = composition
        }
        return appDelegate
    }

    func makeAppDelegateWithMainWindow() -> (
        appDelegate: AppDelegate,
        tabManager: TabManager,
        mainWindow: MainWindow
    ) {
        let appDelegate = makeAppDelegate()
        let tabManager = TabManager()
        let mainWindow = registerMainWindow(on: appDelegate, tabManager: tabManager)
        return (appDelegate, tabManager, mainWindow)
    }

    func registerMainWindow(on appDelegate: AppDelegate, tabManager: TabManager) -> MainWindow {
        let id = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        appDelegate.tabManager = tabManager
        appDelegate.registerMainWindow(
            window,
            windowId: id,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)
        appDelegate.debugSetShortcutRoutingFocusedWindowForTesting(window)
        let mainWindow = MainWindow(id: id, window: window, tabManager: tabManager)
        registeredMainWindows.append((appDelegate, mainWindow))
        return mainWindow
    }

    func cleanup() {
        for (appDelegate, mainWindow) in registeredMainWindows.reversed() {
            mainWindow.tabManager.tabs.forEach { $0.teardownAllPanels() }
            appDelegate.unregisterMainWindowContextForTesting(windowId: mainWindow.id)
            mainWindow.window.orderOut(nil)
            mainWindow.window.close()
        }
        registeredMainWindows.removeAll()
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
        AppDelegate.shared = originalAppDelegate
        defaults.removePersistentDomain(forName: suiteName)
    }
}
