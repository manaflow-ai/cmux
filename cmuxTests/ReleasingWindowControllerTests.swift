import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct ReleasingWindowControllerTests {
    @Test
    func windowCloseObserverFiresSynchronouslyOnClose() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        var observedWindow: NSWindow?
        let observer = WindowCloseObserver(window: window) { window in
            observedWindow = window
        }

        withExtendedLifetime(observer) {
            window.close()
        }

        #expect(observedWindow === window)
    }

    @Test
    func closeReleasesManagedWindowAndRecreatesOnNextShow() {
        let controller = CountingReleasingWindowController()

        let firstWindow = controller.showManagedWindow()
        #expect(controller.makeWindowCount == 1)
        #expect(controller.window === firstWindow)
        #expect(firstWindow.contentView != nil)
        #expect(firstWindow.delegate === controller)

        firstWindow.close()

        #expect(controller.window == nil)
        #expect(firstWindow.contentView == nil)
        #expect(firstWindow.contentViewController == nil)
        #expect(firstWindow.delegate == nil)
        #expect(controller.closedWindowIdentifiers == ["cmux.testReleasingWindow.1"])

        let secondWindow = controller.showManagedWindow()
        defer { secondWindow.close() }

        #expect(controller.makeWindowCount == 2)
        #expect(secondWindow !== firstWindow)
        #expect(controller.window === secondWindow)
    }

    @Test
    func featureFlagsWindowOwnsCloseShortcutAndReleasesOnClose() throws {
        InternalFlagsPresenter.present()
        let window = try #require(featureFlagsWindow())

        // A panel hides on deactivation and can stay ordered out while AppKit
        // still counts it as visible, which captures Cmd-` cycling.
        #expect(!(window is NSPanel))
        #expect(!window.hidesOnDeactivate)
        #expect(cmuxWindowShouldOwnCloseShortcut(window))

        window.performClose(nil)

        #expect(featureFlagsWindow() == nil)
        #expect(window.contentView == nil)

        // Reopening must build a new window, which proves the close released it.
        InternalFlagsPresenter.present()
        let reopened = try #require(featureFlagsWindow())
        defer { reopened.close() }
        #expect(reopened !== window)
    }

    private func featureFlagsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "cmux.featureFlags" && $0.isVisible }
    }

    private final class CountingReleasingWindowController: ReleasingWindowController {
        var makeWindowCount = 0
        var closedWindowIdentifiers: [String] = []

        override func makeWindow() -> NSWindow {
            makeWindowCount += 1
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.identifier = NSUserInterfaceItemIdentifier("cmux.testReleasingWindow.\(makeWindowCount)")
            window.contentView = NSView(frame: window.contentLayoutRect)
            return window
        }

        override func managedWindowWillClose(_ window: NSWindow) {
            closedWindowIdentifiers.append(window.identifier?.rawValue ?? "<nil>")
        }
    }
}
