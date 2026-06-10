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

    // MARK: - Multi-monitor recovery (issue #5770)

    // A frame saved on a now-disconnected display sits off every active screen.
    // Selection must recover onto the screen under the cursor instead of leaving
    // Settings offscreen (the "nothing shows up" multi-monitor symptom).
    func testTargetVisibleFrameRecoversOffscreenFrameOntoCursorScreen() {
        let primary = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        let secondary = NSRect(x: 1800, y: 0, width: 1600, height: 900)
        // Saved on a third display to the far left that is no longer connected.
        let orphanFrame = NSRect(x: -2400, y: 400, width: 980, height: 680)

        let target = SettingsWindowPresenter.targetVisibleFrame(
            windowFrame: orphanFrame,
            screenVisibleFrames: [primary, secondary],
            mouseLocation: NSPoint(x: 2000, y: 450), // cursor is on the secondary screen
            fallbackVisibleFrame: primary
        )

        XCTAssertEqual(target, secondary)
    }

    // When the cursor is also off every active screen, fall back to main/first.
    func testTargetVisibleFrameFallsBackWhenOffscreenAndCursorElsewhere() {
        let primary = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        let orphanFrame = NSRect(x: -2400, y: 400, width: 980, height: 680)

        let target = SettingsWindowPresenter.targetVisibleFrame(
            windowFrame: orphanFrame,
            screenVisibleFrames: [primary],
            mouseLocation: NSPoint(x: -3000, y: 9000), // cursor off all screens too
            fallbackVisibleFrame: primary
        )

        XCTAssertEqual(target, primary)
    }

    // A window mostly on a screen stays on that screen even if another exists.
    func testTargetVisibleFramePrefersScreenWithMostOverlap() {
        let primary = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        let secondary = NSRect(x: 1800, y: 0, width: 1600, height: 900)
        let mostlyOnSecondary = NSRect(x: 1900, y: 100, width: 980, height: 680)

        let target = SettingsWindowPresenter.targetVisibleFrame(
            windowFrame: mostlyOnSecondary,
            screenVisibleFrames: [primary, secondary],
            mouseLocation: NSPoint(x: 10, y: 10), // cursor on primary, but window is on secondary
            fallbackVisibleFrame: primary
        )

        XCTAssertEqual(target, secondary)
    }

    func testClampedFrameMovesOffscreenOriginInsideTargetScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        let inset: CGFloat = 18
        // Origin far to the left/below the target screen.
        let offscreen = NSRect(x: -5000, y: -5000, width: 980, height: 680)

        let clamped = SettingsWindowPresenter.clampedFrame(
            offscreen,
            minimumSize: SettingsWindowPresenter.minimumSize,
            into: visible,
            inset: inset
        )

        XCTAssertEqual(clamped.size, offscreen.size)
        XCTAssertGreaterThanOrEqual(clamped.minX, visible.minX + inset)
        XCTAssertGreaterThanOrEqual(clamped.minY, visible.minY + inset)
        XCTAssertLessThanOrEqual(clamped.maxX, visible.maxX - inset)
        XCTAssertLessThanOrEqual(clamped.maxY, visible.maxY - inset)
    }

    func testClampedFrameShrinksOversizedFrameToVisibleArea() {
        let visible = NSRect(x: 100, y: 100, width: 1200, height: 800)
        let inset: CGFloat = 18
        let oversized = NSRect(x: 0, y: 0, width: 4000, height: 4000)

        let clamped = SettingsWindowPresenter.clampedFrame(
            oversized,
            minimumSize: SettingsWindowPresenter.minimumSize,
            into: visible,
            inset: inset
        )

        XCTAssertLessThanOrEqual(clamped.width, visible.width - 2 * inset)
        XCTAssertLessThanOrEqual(clamped.height, visible.height - 2 * inset)
        XCTAssertGreaterThanOrEqual(clamped.width, SettingsWindowPresenter.minimumSize.width)
        XCTAssertGreaterThanOrEqual(clamped.height, SettingsWindowPresenter.minimumSize.height)
    }

    // MARK: - Silent no-op recovery (issue #5770 / #4053)

    func testOpenOutcomeRetriesWhenWindowDoesNotMaterializeOnFirstAttempt() {
        XCTAssertEqual(
            SettingsWindowPresenter.openOutcome(windowExists: false, attempt: 1),
            .retry
        )
    }

    func testOpenOutcomeGivesUpAfterMaxAttempts() {
        XCTAssertEqual(
            SettingsWindowPresenter.openOutcome(
                windowExists: false,
                attempt: SettingsWindowPresenter.maxOpenAttempts
            ),
            .giveUp
        )
    }

    func testOpenOutcomeIsMaterializedWhenWindowExists() {
        XCTAssertEqual(
            SettingsWindowPresenter.openOutcome(windowExists: true, attempt: 1),
            .materialized
        )
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
