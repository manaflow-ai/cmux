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
    @MainActor
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

    /// Waits until the presenter's close fallback is sleeping on `clock`.
    private func fallbackArmed(on clock: SidebarTestManualClock) async -> Bool {
        await AppKitTestEventPump().waitUntil(timeout: .seconds(3)) { clock.sleeperCount == 1 }
    }

    private func closeCompleted(_ presenter: SidebarRowSwiftUIPopoverPresenter) async -> Bool {
        await AppKitTestEventPump().waitUntil(timeout: .seconds(3)) {
            !presenter.isShown && !presenter.isClosing
        }
    }

    @Test
    func userCloseWhoseAnimationNeverFinishesStillCompletes() async throws {
        let host = Host()
        let clock = SidebarTestManualClock()
        let presenter = SidebarRowSwiftUIPopoverPresenter(closeCompletionClock: clock)
        defer { host.tearDown(presenter) }
        var dismissals = 0
        presenter.onExternalDismiss = { dismissals += 1 }
        host.present(presenter)
        try #require(presenter.isShown)

        // AppKit starts a click-away close, and its `popoverDidClose` never
        // arrives, as on the affected hosts.
        presenter.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        #expect(presenter.isClosing)
        #expect(await fallbackArmed(on: clock), "willClose should arm a bounded close fallback")
        #expect(presenter.isClosing, "The close is still in flight before the deadline")

        clock.advance(by: .seconds(1))
        #expect(await closeCompleted(presenter), "A close whose animation never finishes should still complete")
        #expect(dismissals == 1, "The click-away should be reported as an external dismissal once")

        // The next toggle presents a new popover instead of closing the stuck
        // one, and that popover animates its own close again.
        host.present(presenter)
        #expect(presenter.isShown)
        #expect(!presenter.isClosing)
        #expect(presenter.popover?.animates == true)
    }

    @Test
    func repeatedWillCloseKeepsTheFirstDeadline() async throws {
        let host = Host()
        let clock = SidebarTestManualClock()
        let presenter = SidebarRowSwiftUIPopoverPresenter(closeCompletionClock: clock)
        defer { host.tearDown(presenter) }
        host.present(presenter)
        try #require(presenter.isShown)

        let willClose = Notification(name: NSPopover.willCloseNotification)
        presenter.popoverWillClose(willClose)
        #expect(await fallbackArmed(on: clock))
        clock.advance(by: .milliseconds(600))
        presenter.popoverWillClose(willClose)
        await AppKitTestEventPump().drain()

        // One second after the first willClose, not after the second.
        clock.advance(by: .milliseconds(400))
        #expect(await closeCompleted(presenter), "A repeated willClose must not push completion back")
    }

    @Test
    func representingAHiddenPopoverCancelsThePendingFallback() async throws {
        let host = Host()
        let clock = SidebarTestManualClock()
        let presenter = SidebarRowSwiftUIPopoverPresenter(closeCompletionClock: clock)
        defer { host.tearDown(presenter) }
        var dismissals = 0
        presenter.onExternalDismiss = { dismissals += 1 }
        host.present(presenter)
        let popover = try #require(presenter.popover)
        try #require(presenter.isShown)

        // A close starts and the popover goes hidden, but its didClose has
        // not reached the presenter yet when the container presents again.
        presenter.popoverWillClose(Notification(name: NSPopover.willCloseNotification, object: popover))
        #expect(await fallbackArmed(on: clock))
        popover.delegate = nil
        popover.animates = false
        popover.close()
        popover.delegate = presenter
        try #require(!presenter.isShown)

        host.present(presenter)
        #expect(presenter.isShown)
        #expect(!presenter.isClosing, "Presenting again supersedes the close in flight")
        #expect(clock.sleeperCount == 0, "Presenting again cancels the superseded fallback")

        // The old deadline passing must not abandon the popover now showing.
        clock.advance(by: .seconds(1))
        await AppKitTestEventPump().drain()
        #expect(presenter.isShown, "The superseded fallback must not close the re-presented popover")
        #expect(presenter.popover === popover)

        // The superseded close's didClose arriving late must not tear down
        // or report a dismissal of the popover now showing.
        presenter.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        #expect(presenter.isShown, "A late didClose must not close the re-presented popover")
        #expect(presenter.popover === popover)
        #expect(dismissals == 0, "A late didClose is not an external dismissal")
    }

    @Test
    func toggleCloseIsNeverAnExternalDismissal() async throws {
        let host = Host()
        let clock = SidebarTestManualClock()
        let presenter = SidebarRowSwiftUIPopoverPresenter(closeCompletionClock: clock)
        defer { host.tearDown(presenter) }
        var dismissals = 0
        presenter.onExternalDismiss = { dismissals += 1 }
        host.present(presenter)
        try #require(presenter.isShown)

        // A real animated close. Healthy hosts deliver didClose; affected
        // hosts never do. Past the fallback's deadline, either way ends the
        // close, and neither may report the toggle as the user dismissing
        // the popover from outside.
        presenter.close()
        _ = await AppKitTestEventPump().waitUntil(timeout: .seconds(3)) {
            clock.sleeperCount == 1 || !presenter.isClosing
        }
        clock.advance(by: .seconds(1))
        #expect(await closeCompleted(presenter))
        await AppKitTestEventPump().drain()
        #expect(dismissals == 0)

        host.present(presenter)
        #expect(presenter.isShown)
    }
}
