import AppKit
import CmuxSettings
import CmuxWorkspaces
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// One user action produces at most one close dialog. When the user already
/// accepted "Close window?" or a workspace close dialog, the window close that
/// follows must reach the should-close path marked as confirmed, so the
/// last-window path does not add a second "Quit cmux?" dialog.
@MainActor
final class MainWindowCloseConfirmationTests: XCTestCase {
    private var createdWindowIds: [UUID] = []

    override func tearDown() {
        let appDelegate = AppDelegate.shared
#if DEBUG
        appDelegate?.mainWindowShouldCloseObserverForTesting = nil
#endif
        appDelegate?.debugCloseMainWindowDontAskAgainHandler = nil
        appDelegate?.debugCloseMainWindowConfirmationHandler = { _ in true }
        for windowId in createdWindowIds {
            if let window = window(withId: windowId) {
                window.animationBehavior = .none
                window.orderOut(nil)
                window.close()
            }
        }
        createdWindowIds.removeAll()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        appDelegate?.debugCloseMainWindowConfirmationHandler = nil
        super.tearDown()
    }

#if DEBUG
    func testConfirmedCloseWindowReachesShouldCloseAsConfirmed() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let targetWindow = try makeMainWindow(appDelegate)
        try setShellActivity(.commandRunning, appDelegate)

        var prompts = 0
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in
            prompts += 1
            return true
        }
        let requests = recordShouldCloseRequests(appDelegate)

        appDelegate.closeWindowWithConfirmation(targetWindow)

        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(requests.values.count, 1)
        XCTAssertTrue(requests.values.first?.window === targetWindow)
        XCTAssertEqual(
            requests.values.first?.confirmed,
            true,
            "An accepted Close window? dialog must carry through so the last window does not also ask to quit"
        )
    }

    func testCancelledCloseWindowNeverReachesShouldClose() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let targetWindow = try makeMainWindow(appDelegate)
        try setShellActivity(.commandRunning, appDelegate)

        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in false }
        let requests = recordShouldCloseRequests(appDelegate)

        appDelegate.closeWindowWithConfirmation(targetWindow)

        XCTAssertTrue(requests.values.isEmpty)
        XCTAssertTrue(targetWindow.isVisible)
    }

    func testIdleWindowClosesWithoutCloseWindowPrompt() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let targetWindow = try makeMainWindow(appDelegate)
        try setShellActivity(.promptIdle, appDelegate)

        var prompts = 0
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in
            prompts += 1
            return false
        }
        let requests = recordShouldCloseRequests(appDelegate)

        appDelegate.closeWindowWithConfirmation(targetWindow)

        XCTAssertEqual(prompts, 0, "Nothing would be lost, so Close Window must not ask")
        XCTAssertEqual(requests.values.count, 1)
        XCTAssertTrue(requests.values.first?.window === targetWindow)
        XCTAssertEqual(
            requests.values.first?.confirmed,
            false,
            "A close that skipped the dialog leaves the last-window quit policy as the one confirmation"
        )
    }

    func testWindowWarningOffStillPromptsForRunningWindow() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let targetWindow = try makeMainWindow(appDelegate)
        try setShellActivity(.commandRunning, appDelegate)
        let defaults = UserDefaults.standard
        let key = AppCatalogSection().warnBeforeClosingWindow.userDefaultsKey
        let original = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        var prompts = 0
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in
            prompts += 1
            return false
        }
        let requests = recordShouldCloseRequests(appDelegate)

        appDelegate.closeWindowWithConfirmation(targetWindow)

        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(requests.values.count, 0)
    }

    func testTickingDontAskAgainTurnsOffWindowWarning() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let targetWindow = try makeMainWindow(appDelegate)
        try setShellActivity(.commandRunning, appDelegate)
        let defaults = UserDefaults.standard
        let key = AppCatalogSection().warnBeforeClosingWindow.userDefaultsKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        var prompts = 0
        var offered: [CloseWarningKinds] = []
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in
            prompts += 1
            return false
        }
        appDelegate.debugCloseMainWindowDontAskAgainHandler = { kinds in
            offered.append(kinds)
            return true
        }

        // Cancel with the box ticked: the window stays and the ordinary window
        // warning turns off, while the live-process safety warning remains.
        appDelegate.closeWindowWithConfirmation(targetWindow)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(offered, [.window, .safety])
        XCTAssertFalse(AppCatalogSection().warnBeforeClosingWindow.value(in: defaults))
        XCTAssertTrue(targetWindow.isVisible)

        let requests = recordShouldCloseRequests(appDelegate)
        appDelegate.closeWindowWithConfirmation(targetWindow)
        XCTAssertEqual(prompts, 2, "The safety warning cannot be disabled")
        XCTAssertEqual(requests.values.count, 0)
    }

    func testUnconfirmedWindowCloseStillReachesShouldCloseUnconfirmed() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let targetWindow = try makeMainWindow(appDelegate)
        let requests = recordShouldCloseRequests(appDelegate)

        // The title-bar close button goes straight to performClose with no cmux
        // dialog, so the last-window quit policy remains the one confirmation.
        targetWindow.performClose(nil)

        XCTAssertEqual(requests.values.count, 1)
        XCTAssertEqual(requests.values.first?.confirmed, false)
    }

    func testConfirmedPinnedLastWorkspaceCloseReachesShouldCloseAsConfirmed() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let targetWindow = try makeMainWindow(appDelegate)
        let windowId = try XCTUnwrap(createdWindowIds.last)
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        XCTAssertEqual(manager.tabs.count, 1)
        manager.setPinned(workspace, pinned: true)

        var prompts: [String] = []
        manager.confirmCloseHandler = { title, _, _ in
            prompts.append(title)
            return true
        }
        let requests = recordShouldCloseRequests(appDelegate)

        XCTAssertTrue(manager.closeWorkspaceWithConfirmation(workspace))

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(requests.values.count, 1)
        XCTAssertTrue(requests.values.first?.window === targetWindow)
        XCTAssertEqual(
            requests.values.first?.confirmed,
            true,
            "An accepted workspace close dialog must carry through to the window close it causes"
        )
    }

    func testConfirmedCloseOfEveryWorkspaceReachesShouldCloseAsConfirmed() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let targetWindow = try makeMainWindow(appDelegate)
        let windowId = try XCTUnwrap(createdWindowIds.last)
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        _ = manager.addWorkspace()
        XCTAssertEqual(manager.tabs.count, 2)

        var prompts = 0
        manager.confirmCloseHandler = { _, _, _ in
            prompts += 1
            return true
        }
        let requests = recordShouldCloseRequests(appDelegate)

        manager.closeWorkspacesWithConfirmation(manager.tabs.map(\.id), allowPinned: true)

        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(requests.values.count, 1)
        XCTAssertTrue(requests.values.first?.window === targetWindow)
        XCTAssertEqual(requests.values.first?.confirmed, true)
    }

    /// Pins every panel in the most recent test window to one shell state, so
    /// the close decision does not depend on the live terminal's prompt marks.
    private func setShellActivity(_ state: PanelShellActivityState, _ appDelegate: AppDelegate) throws {
        let windowId = try XCTUnwrap(createdWindowIds.last)
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        for workspace in manager.tabs {
            for panelId in workspace.panels.keys {
                workspace.updatePanelShellActivityState(panelId: panelId, state: state)
            }
        }
    }

    private final class ShouldCloseRequests {
        var values: [(window: NSWindow, confirmed: Bool)] = []
    }

    private func recordShouldCloseRequests(_ appDelegate: AppDelegate) -> ShouldCloseRequests {
        let requests = ShouldCloseRequests()
        appDelegate.mainWindowShouldCloseObserverForTesting = { window, confirmed in
            requests.values.append((window, confirmed))
        }
        return requests
    }
#endif

    private func makeMainWindow(_ appDelegate: AppDelegate) throws -> NSWindow {
        let windowId = appDelegate.createMainWindow()
        createdWindowIds.append(windowId)
        let window = try XCTUnwrap(window(withId: windowId))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        return window
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }
}
