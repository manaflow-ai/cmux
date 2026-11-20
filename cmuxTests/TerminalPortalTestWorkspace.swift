import AppKit
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Gives portal tests a real selected workspace that can authorize presentation.
@MainActor
final class TerminalPortalTestWorkspace {
    let id: UUID
    var workspace: Workspace { manager.tabs[0] }
    private let manager: TabManager
    private let appDelegate: AppDelegate
    private let previousAppDelegate: AppDelegate?
    private let windowID: UUID

    init() {
        previousAppDelegate = AppDelegate.shared
        appDelegate = previousAppDelegate ?? AppDelegate()
        manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: true)
        id = manager.tabs[0].id
        windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        AppDelegate.shared = appDelegate
    }

    /// Attach the fixture's native window to the same focus authority as its workspace.
    func bind(to window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        _ = appDelegate.contextForMainTerminalWindow(window)
        if let panelID = workspace.focusedPanelId {
            appDelegate.noteMainPanelKeyboardFocusIntent(
                workspaceId: id,
                panelId: panelID,
                in: window
            )
        }
    }

    func tearDown() {
        // The initial workspace owns a default TerminalPanel that is not part
        // of an individual portal fixture's tracked surfaces. Finalize the
        // manager as a closing window so pending selection/materialization
        // work cannot start a replacement runtime after panel teardown.
        manager.closeWorkspacesForTesting()
        appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
        appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
        AppDelegate.shared = previousAppDelegate
    }
}
