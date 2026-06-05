import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
final class SettingsWindowPresenterTests: XCTestCase {
    override func tearDown() {
        SettingsWindowPresenter.resetForTests()
        super.tearDown()
    }

    /// When no Settings window is open and an override is supplied, `show`
    /// invokes the override and leaves the pending navigation target set so the
    /// freshly-created `SettingsWindowRoot` consumes it on appear.
    func testShowWithoutWindowUsesOverrideAndLeavesPendingNavigation() {
        var didOpen = false
        SettingsWindowPresenter.show(
            navigationTarget: .browserImport,
            openWindowOverride: { didOpen = true }
        )

        XCTAssertTrue(didOpen)
        XCTAssertEqual(SettingsWindowPresenter.consumePendingNavigationTarget(), .browserImport)
        XCTAssertEqual(SettingsWindowPresenter.consumePendingContentNavigationTarget(), .browserImport)
        XCTAssertNil(SettingsWindowPresenter.consumePendingNavigationTarget())
        XCTAssertNil(SettingsWindowPresenter.consumePendingContentNavigationTarget())
    }

    // Settings is a top-level *peer* window, not a child of the main window.
    // Focusing it must never create a parent-child relationship (the floating
    // Settings bug, https://github.com/manaflow-ai/cmux/issues/5081) and must
    // leave it at `.normal` level.
    func testPerformFocusKeepsSettingsAsPeerNotChild() {
        let parentWindow = makeWindow(identifier: "cmux.main.\(UUID().uuidString)")
        let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
        defer {
            settingsWindow.orderOut(nil)
            parentWindow.orderOut(nil)
        }

        SettingsWindowPresenter.performFocusForTests(settingsWindow, parentWindowProvider: { parentWindow })

        XCTAssertNil(settingsWindow.parent)
        XCTAssertFalse(parentWindow.childWindows?.contains(where: { $0 === settingsWindow }) == true)
        XCTAssertEqual(settingsWindow.level, .normal)
    }

    func testAdoptCmuxPeerWindowLevelBringsFloatingWindowToNormal() {
        let window = makeWindow(identifier: "cmux.peer.\(UUID().uuidString)")
        defer { window.orderOut(nil) }

        window.level = .floating
        XCTAssertEqual(window.level, .floating)

        window.adoptCmuxPeerWindowLevel()

        XCTAssertEqual(window.level, .normal)
    }

    func testPerformFocusClampsOversizedSettingsFrameToVisibleArea() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available for Settings frame clamping")
        }
        let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
        settingsWindow.minSize = SettingsWindowPresenter.minimumSize
        settingsWindow.contentMinSize = SettingsWindowPresenter.minimumSize
        let visibleFrame = screen.visibleFrame
        settingsWindow.setFrame(
            NSRect(
                x: visibleFrame.minX - 120,
                y: visibleFrame.minY - 120,
                width: visibleFrame.width * 2,
                height: visibleFrame.height * 2
            ),
            display: false
        )
        defer { settingsWindow.orderOut(nil) }

        SettingsWindowPresenter.performFocusForTests(settingsWindow)

        let inset: CGFloat = 18
        let availableWidth = max(SettingsWindowPresenter.minimumSize.width, visibleFrame.width - 2 * inset)
        let availableHeight = max(SettingsWindowPresenter.minimumSize.height, visibleFrame.height - 2 * inset)
        let frame = settingsWindow.frame
        XCTAssertLessThanOrEqual(frame.width, availableWidth)
        XCTAssertLessThanOrEqual(frame.height, availableHeight)
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX + inset)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY + inset)
    }

    private func makeWindow(identifier: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        return window
    }
}
#endif
