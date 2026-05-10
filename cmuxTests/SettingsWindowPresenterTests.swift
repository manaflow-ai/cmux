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

    func testConfigureWindowLeavesPendingNavigationForSettingsViews() {
        let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
        var didOpen = false
        defer {
            settingsWindow.orderOut(nil)
        }

        SettingsWindowPresenter.show(
            navigationTarget: .browserImport,
            openWindowOverride: { didOpen = true }
        )
        SettingsWindowPresenter.configure(window: settingsWindow)

        XCTAssertTrue(didOpen)
        XCTAssertEqual(SettingsWindowPresenter.consumePendingNavigationTarget(), .browserImport)
        XCTAssertEqual(SettingsWindowPresenter.consumePendingContentNavigationTarget(), .browserImport)
        XCTAssertNil(SettingsWindowPresenter.consumePendingNavigationTarget())
        XCTAssertNil(SettingsWindowPresenter.consumePendingContentNavigationTarget())
    }

    func testParentsSettingsAbovePreferredMainWindow() {
        let parentWindow = makeWindow(identifier: "cmux.main.\(UUID().uuidString)")
        let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
        defer {
            settingsWindow.orderOut(nil)
            parentWindow.orderOut(nil)
        }

        SettingsWindowPresenter.configure(
            openWindow: {},
            parentWindowProvider: { parentWindow }
        )
        SettingsWindowPresenter.configure(window: settingsWindow)

        XCTAssertTrue(settingsWindow.parent === parentWindow)
        XCTAssertTrue(parentWindow.childWindows?.contains(where: { $0 === settingsWindow }) == true)
    }

    func testReparentsSettingsWhenPreferredMainWindowChanges() {
        let firstParent = makeWindow(identifier: "cmux.main.\(UUID().uuidString)")
        let secondParent = makeWindow(identifier: "cmux.main.\(UUID().uuidString)")
        let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
        var preferredParent = firstParent
        defer {
            settingsWindow.orderOut(nil)
            firstParent.orderOut(nil)
            secondParent.orderOut(nil)
        }

        SettingsWindowPresenter.configure(
            openWindow: {},
            parentWindowProvider: { preferredParent }
        )
        SettingsWindowPresenter.configure(window: settingsWindow)
        XCTAssertTrue(settingsWindow.parent === firstParent)

        preferredParent = secondParent
        SettingsWindowPresenter.refocusIfVisible()
        XCTAssertTrue(settingsWindow.parent === firstParent)

        settingsWindow.orderFront(nil)
        SettingsWindowPresenter.refocusIfVisible()

        XCTAssertTrue(settingsWindow.parent === secondParent)
        XCTAssertFalse(firstParent.childWindows?.contains(where: { $0 === settingsWindow }) == true)
        XCTAssertTrue(secondParent.childWindows?.contains(where: { $0 === settingsWindow }) == true)
    }

    func testDetachesSettingsBeforePreferredMainWindowCloses() {
        let parentWindow = makeWindow(identifier: "cmux.main.\(UUID().uuidString)")
        let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
        defer {
            settingsWindow.orderOut(nil)
            parentWindow.orderOut(nil)
        }

        SettingsWindowPresenter.configure(
            openWindow: {},
            parentWindowProvider: { parentWindow }
        )
        SettingsWindowPresenter.configure(window: settingsWindow)
        settingsWindow.orderFront(nil)
        XCTAssertTrue(settingsWindow.parent === parentWindow)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: parentWindow)

        XCTAssertNil(settingsWindow.parent)
        XCTAssertFalse(parentWindow.childWindows?.contains(where: { $0 === settingsWindow }) == true)
        XCTAssertTrue(settingsWindow.isVisible)
    }

    func testConfigureClampsOversizedSettingsFrameToVisibleArea() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available for Settings frame clamping")
        }
        let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
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
        defer {
            settingsWindow.orderOut(nil)
        }

        SettingsWindowPresenter.configure(window: settingsWindow)

        let inset: CGFloat = 18
        let availableWidth = max(
            SettingsWindowPresenter.minimumSize.width,
            visibleFrame.width - 2 * inset
        )
        let availableHeight = max(
            SettingsWindowPresenter.minimumSize.height,
            visibleFrame.height - 2 * inset
        )
        let frame = settingsWindow.frame
        XCTAssertLessThanOrEqual(frame.width, availableWidth)
        XCTAssertLessThanOrEqual(frame.height, availableHeight)
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX + inset)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY + inset)
        if frame.width <= visibleFrame.width - 2 * inset {
            XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX - inset)
        }
        if frame.height <= visibleFrame.height - 2 * inset {
            XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY - inset)
        }
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
