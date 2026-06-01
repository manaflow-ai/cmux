import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
// `.serialized`: every test mutates `SettingsWindowPresenter`'s shared static
// state and resets it on exit, so they must not run concurrently with each
// other (Swift Testing parallelizes by default).
@MainActor
@Suite(.serialized)
struct SettingsWindowPresenterTests {
    @Test func configureWindowAppliesModernSettingsChrome() {
        defer { SettingsWindowPresenter.resetForTests() }
        let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
        defer {
            settingsWindow.orderOut(nil)
        }

        SettingsWindowPresenter.configure(window: settingsWindow)

        #expect(settingsWindow.toolbarStyle == .unifiedCompact)
        #expect(settingsWindow.styleMask.contains(.fullSizeContentView))
        #expect(settingsWindow.titlebarAppearsTransparent)
        #expect(settingsWindow.titleVisibility == .hidden)
        #expect(settingsWindow.titlebarSeparatorStyle == .none)
        #expect(settingsWindow.toolbar != nil)
    }

    @Test func configureWindowLeavesPendingNavigationForSettingsViews() {
        defer { SettingsWindowPresenter.resetForTests() }
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

        #expect(didOpen)
        #expect(SettingsWindowPresenter.consumePendingNavigationTarget() == .browserImport)
        #expect(SettingsWindowPresenter.consumePendingContentNavigationTarget() == .browserImport)
        #expect(SettingsWindowPresenter.consumePendingNavigationTarget() == nil)
        #expect(SettingsWindowPresenter.consumePendingContentNavigationTarget() == nil)
    }

    @Test func repeatedConfigureForSameSettingsWindowDoesNotRefocus() async {
        defer { SettingsWindowPresenter.resetForTests() }
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

        #expect(focusedWindows.count == 1)
        #expect(focusedWindows.first === settingsWindow)
    }

    @Test func showPreservesPendingNavigationWhenExistingSettingsWindowIsMiniaturized() async {
        defer { SettingsWindowPresenter.resetForTests() }
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

        #expect(!didOpen)
        #expect(SettingsWindowPresenter.consumePendingNavigationTarget() == .browserImport)
        #expect(SettingsWindowPresenter.consumePendingContentNavigationTarget() == .browserImport)
    }

    @Test func parentsSettingsAbovePreferredMainWindow() {
        defer { SettingsWindowPresenter.resetForTests() }
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

        #expect(settingsWindow.parent === parentWindow)
        #expect(parentWindow.childWindows?.contains(where: { $0 === settingsWindow }) == true)
    }

    @Test func reparentsSettingsWhenPreferredMainWindowChanges() {
        defer { SettingsWindowPresenter.resetForTests() }
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
        #expect(settingsWindow.parent === firstParent)

        preferredParent = secondParent
        SettingsWindowPresenter.refocusIfVisible()
        #expect(settingsWindow.parent === firstParent)

        settingsWindow.orderFront(nil)
        SettingsWindowPresenter.refocusIfVisible()

        #expect(settingsWindow.parent === secondParent)
        #expect(firstParent.childWindows?.contains(where: { $0 === settingsWindow }) != true)
        #expect(secondParent.childWindows?.contains(where: { $0 === settingsWindow }) == true)
    }

    @Test func detachesSettingsBeforePreferredMainWindowCloses() {
        defer { SettingsWindowPresenter.resetForTests() }
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
        #expect(settingsWindow.parent === parentWindow)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: parentWindow)

        #expect(settingsWindow.parent == nil)
        #expect(parentWindow.childWindows?.contains(where: { $0 === settingsWindow }) != true)
        #expect(settingsWindow.isVisible)
    }

    @Test func configureClampsOversizedSettingsFrameToVisibleArea() {
        defer { SettingsWindowPresenter.resetForTests() }
        // Skip when no screen is available (headless runner): there is no
        // visible area to clamp against. Mirrors the previous `XCTSkip`.
        guard let screen = NSScreen.main else { return }
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
        #expect(frame.width <= availableWidth)
        #expect(frame.height <= availableHeight)
        #expect(frame.minX >= visibleFrame.minX + inset)
        #expect(frame.minY >= visibleFrame.minY + inset)
        if frame.width <= visibleFrame.width - 2 * inset {
            #expect(frame.maxX <= visibleFrame.maxX - inset)
        }
        if frame.height <= visibleFrame.height - 2 * inset {
            #expect(frame.maxY <= visibleFrame.maxY - inset)
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
