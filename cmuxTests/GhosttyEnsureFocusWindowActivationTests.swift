import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GhosttyEnsureFocusWindowActivationTests: XCTestCase {
    func testAllowsActivationForActiveManager() {
        let activeManager = TabManager()
        let otherManager = TabManager()
        let targetWindow = NSWindow()
        let otherWindow = NSWindow()

        XCTAssertTrue(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: activeManager,
                targetTabManager: activeManager,
                keyWindow: targetWindow,
                mainWindow: targetWindow,
                targetWindow: targetWindow
            )
        )
        XCTAssertFalse(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: activeManager,
                targetTabManager: otherManager,
                keyWindow: otherWindow,
                mainWindow: otherWindow,
                targetWindow: targetWindow
            )
        )
    }

    func testAllowsActivationWhenAppHasNoKeyAndNoMainWindow() {
        let targetManager = TabManager()
        let targetWindow = NSWindow()

        XCTAssertTrue(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: nil,
                targetTabManager: targetManager,
                keyWindow: nil,
                mainWindow: nil,
                targetWindow: targetWindow
            )
        )
        XCTAssertFalse(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: nil,
                targetTabManager: targetManager,
                keyWindow: NSWindow(),
                mainWindow: nil,
                targetWindow: targetWindow
            )
        )
        XCTAssertFalse(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: nil,
                targetTabManager: targetManager,
                keyWindow: nil,
                mainWindow: NSWindow(),
                targetWindow: targetWindow
            )
        )
    }

    func testRightSidebarFocusOwnerBlocksDeferredTerminalFirstResponderRequest() {
#if DEBUG
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let tabManager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = tabManager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected a focused terminal panel")
            return
        }

        let hostedView = terminalPanel.hostedView
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .files, in: window)

        XCTAssertFalse(
            hostedView.debugRequestSurfaceFirstResponderForTesting(in: window, reason: "test.rightSidebar"),
            "Deferred terminal focus retries should not steal first responder while the right sidebar owns keyboard focus"
        )
        XCTAssertFalse(hostedView.isSurfaceViewFirstResponder())
#else
        XCTFail("debugRequestSurfaceFirstResponderForTesting is only available in DEBUG")
#endif
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
