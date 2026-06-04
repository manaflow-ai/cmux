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

    func testRepeatedConfigureForSameSettingsWindowDoesNotRefocus() async {
        let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
        var focusedWindows: [NSWindow] = []
        defer {
            settingsWindow.orderOut(nil)
        }

        SettingsWindowPresenter.setFocusHandlerForTests { window in
            focusedWindows.append(window)
        }

        SettingsWindowPresenter.configure(window: settingsWindow)
        await Task.yield()
        SettingsWindowPresenter.configure(window: settingsWindow)
        await Task.yield()

        XCTAssertEqual(focusedWindows.count, 1)
        XCTAssertTrue(focusedWindows.first === settingsWindow)
    }

    func testShowPreservesPendingNavigationWhenExistingSettingsWindowIsMiniaturized() async {
        let settingsWindow = makeWindow(
            identifier: SettingsWindowPresenter.windowIdentifier,
            isMiniaturizedForTests: true
        )
        var didOpen = false
        defer {
            settingsWindow.orderOut(nil)
        }

        SettingsWindowPresenter.setFocusHandlerForTests { _ in }
        SettingsWindowPresenter.configure(window: settingsWindow)
        await Task.yield()

        SettingsWindowPresenter.show(
            navigationTarget: .browserImport,
            openWindowOverride: { didOpen = true }
        )

        XCTAssertFalse(didOpen)
        XCTAssertEqual(SettingsWindowPresenter.consumePendingNavigationTarget(), .browserImport)
        XCTAssertEqual(SettingsWindowPresenter.consumePendingContentNavigationTarget(), .browserImport)
    }

    // Settings is a top-level *peer* window, not a child of the main window.
    // A child window (`addChildWindow`) is pinned above its parent forever and
    // can never recede when the user clicks the main window — that is the
    // floating-Settings bug (https://github.com/manaflow-ai/cmux/issues/5081).
    // These tests pin the peer invariant: configuring/focusing Settings must
    // never create a parent-child relationship and must leave it at `.normal`.
    func testDoesNotAttachSettingsAsChildOfPreferredMainWindow() {
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

        XCTAssertNil(settingsWindow.parent)
        XCTAssertFalse(parentWindow.childWindows?.contains(where: { $0 === settingsWindow }) == true)
        XCTAssertEqual(settingsWindow.level, .normal)
    }

    func testFocusingSettingsKeepsItAsPeerWhenPreferredMainWindowChanges() {
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
        XCTAssertNil(settingsWindow.parent)

        preferredParent = secondParent
        settingsWindow.orderFront(nil)
        // refocusIfVisible() runs the real performFocus ordering path.
        SettingsWindowPresenter.refocusIfVisible()

        XCTAssertNil(settingsWindow.parent)
        XCTAssertFalse(firstParent.childWindows?.contains(where: { $0 === settingsWindow }) == true)
        XCTAssertFalse(secondParent.childWindows?.contains(where: { $0 === settingsWindow }) == true)
        XCTAssertEqual(settingsWindow.level, .normal)
    }

    func testSettingsSurvivesPreferredMainWindowCloseAsIndependentPeer() {
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
        XCTAssertNil(settingsWindow.parent)

        // As an independent peer, Settings is unaffected by the main window
        // closing — there is no child relationship to tear down.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: parentWindow)

        XCTAssertNil(settingsWindow.parent)
        XCTAssertTrue(settingsWindow.isVisible)
    }

    func testAdoptCmuxPeerWindowLevelBringsFloatingWindowToNormal() {
        let window = makeWindow(identifier: "cmux.peer.\(UUID().uuidString)")
        defer { window.orderOut(nil) }

        window.level = .floating
        XCTAssertEqual(window.level, .floating)

        window.adoptCmuxPeerWindowLevel()

        XCTAssertEqual(window.level, .normal)
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

    private func makeWindow(
        identifier: String,
        isMiniaturizedForTests: Bool? = nil
    ) -> NSWindow {
        let window = TestSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isMiniaturizedForTests = isMiniaturizedForTests
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        return window
    }

    private final class TestSettingsWindow: NSWindow {
        var isMiniaturizedForTests: Bool?

        override var isMiniaturized: Bool {
            isMiniaturizedForTests ?? super.isMiniaturized
        }
    }
}
#endif
