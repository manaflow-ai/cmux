import AppKit
import SwiftUI
import Testing
@testable import cmux_DEV

/// On some owned Mac minis an animated `NSPopover` close starts
/// (`popoverWillClose`) but never finishes (`popoverDidClose`). The presenter
/// must not stay "closing" forever: that left `isShown` true, so every later
/// toggle closed the stuck popover again instead of presenting a new one.
@Suite(.serialized)
@MainActor
struct SidebarRowSwiftUIPopoverPresenterTests {
    private final class Host {
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let window: NSWindow

        init() {
            window = NSWindow(
                contentRect: anchor.bounds,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = anchor
            window.orderFront(nil)
        }

        func present(_ presenter: SidebarRowSwiftUIPopoverPresenter) {
            presenter.present(
                AnyView(Text(verbatim: "Checklist")),
                relativeTo: NSRect(x: anchor.bounds.width - 1, y: 0, width: 1, height: 1),
                of: anchor,
                preferredEdge: .maxX
            )
        }

        func tearDown(_ presenter: SidebarRowSwiftUIPopoverPresenter) {
            presenter.onExternalDismiss = nil
            presenter.close()
            window.contentView = nil
            window.close()
        }
    }

    @Test
    func userCloseWhoseAnimationNeverFinishesStillCompletes() async throws {
        let host = Host()
        let presenter = SidebarRowSwiftUIPopoverPresenter()
        defer { host.tearDown(presenter) }
        var dismissals = 0
        presenter.onExternalDismiss = { dismissals += 1 }
        host.present(presenter)
        try #require(presenter.isShown)

        // AppKit starts a click-away close, and its `popoverDidClose` never
        // arrives, as on the affected hosts.
        presenter.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        #expect(presenter.isClosing)

        let completed = await AppKitTestEventPump().waitUntil(timeout: .seconds(3)) {
            !presenter.isShown && !presenter.isClosing
        }
        #expect(completed, "A close whose animation never finishes should still complete")
        #expect(dismissals == 1, "The click-away should be reported as an external dismissal once")

        // The next toggle presents a new popover instead of closing the stuck one.
        host.present(presenter)
        #expect(presenter.isShown)
        #expect(!presenter.isClosing)
    }

    @Test
    func toggleCloseWhoseAnimationNeverFinishesIsNotAnExternalDismissal() async throws {
        let host = Host()
        let presenter = SidebarRowSwiftUIPopoverPresenter()
        defer { host.tearDown(presenter) }
        var dismissals = 0
        presenter.onExternalDismiss = { dismissals += 1 }
        host.present(presenter)
        try #require(presenter.isShown)

        presenter.close()
        let completed = await AppKitTestEventPump().waitUntil(timeout: .seconds(3)) {
            !presenter.isShown && !presenter.isClosing
        }
        #expect(completed)
        // Past the fallback's deadline: a programmatic close must not be
        // reported as the user dismissing the popover from outside.
        try await Task.sleep(for: .milliseconds(1_500))
        await AppKitTestEventPump().drain()
        #expect(dismissals == 0)

        host.present(presenter)
        #expect(presenter.isShown)
    }
}
