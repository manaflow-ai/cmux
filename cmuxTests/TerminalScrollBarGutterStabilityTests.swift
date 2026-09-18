import AppKit
import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The terminal grid must not depend on the terminal's own content.
///
/// A legacy scroller reserves a gutter. When its presence followed scrollback,
/// a Cloud mirror whose replay reset empties history reported a new grid after
/// every remote `resized` replay, the remote PTY resized again and replayed
/// again, and Codex received a SIGWINCH storm that garbled and flickered its
/// frame (https://github.com/manaflow-ai/cmux/issues/12885). The same
/// dependency reflowed a local pane when its first row scrolled off
/// (https://github.com/manaflow-ai/cmux/issues/3051).
@MainActor
@Suite("Terminal scroll bar gutter stability", .serialized)
struct TerminalScrollBarGutterStabilityTests {
    /// A pane hosted in an offscreen window so the scroll view tiles for real.
    @MainActor
    private final class Harness {
        let window: NSWindow
        let hostedView: GhosttySurfaceScrollView
        let paneWidth: CGFloat = 640

        init(scrollerStyle: NSScroller.Style) {
            let surfaceView = GhosttyNSView(frame: .zero)
            hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: 400),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(hostedView)
            hostedView.frame = window.contentView?.bounds ?? .zero
            // The hosted view leaves the style to AppKit, which derives it from
            // the system preference; pin it on the scroll view itself, the
            // object AppKit tiles by, so the test is the same on every Mac.
            let scrollView = hostedView.subviews.compactMap { $0 as? NSScrollView }.first
            scrollView?.scrollerStyle = scrollerStyle
            hostedView.needsLayout = true
            hostedView.layoutSubtreeIfNeeded()
        }

        /// Publishes one Ghostty scrollbar packet the way the runtime does and
        /// returns the width the terminal surface is laid out with afterwards.
        func contentWidth(after scrollbar: GhosttyScrollbar) -> CGFloat {
            hostedView.surfaceView.scrollbar = scrollbar
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateScrollbar,
                object: hostedView.surfaceView,
                userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
            )
            hostedView.layoutSubtreeIfNeeded()
            return hostedView.surfaceView.frame.width
        }
    }

    private static let emptyHistory = GhosttyScrollbar(total: 40, offset: 0, len: 40)
    private static let withHistory = GhosttyScrollbar(total: 400, offset: 360, len: 40)

    @Test("A legacy scroller keeps the same content width with and without scrollback")
    func legacyScrollerGutterDoesNotFollowScrollback() {
        let harness = Harness(scrollerStyle: .legacy)
        let gutter = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

        // Attach replay: history exists. Resize replay: the reset (RIS + CSI 3 J)
        // empties it, then the replay refills it. The grid must not move.
        let withHistory = harness.contentWidth(after: Self.withHistory)
        let afterReset = harness.contentWidth(after: Self.emptyHistory)
        let afterReplay = harness.contentWidth(after: Self.withHistory)

        #expect(withHistory == harness.paneWidth - gutter)
        #expect(afterReset == withHistory, "the reset released the legacy gutter and widened the grid")
        #expect(afterReplay == withHistory, "the replay reclaimed the legacy gutter and narrowed the grid")
    }

    @Test("An overlay scroller never changes the content width")
    func overlayScrollerReservesNoGutter() {
        let harness = Harness(scrollerStyle: .overlay)

        let withHistory = harness.contentWidth(after: Self.withHistory)
        let afterReset = harness.contentWidth(after: Self.emptyHistory)

        #expect(withHistory == harness.paneWidth)
        #expect(afterReset == harness.paneWidth)
    }

    @Test("Presence follows scrollback only where it reserves no layout")
    func presencePolicy() {
        typealias Policy = TerminalScrollBarPresencePolicy
        #expect(Policy.isPresent(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: false))
        #expect(Policy.isPresent(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: nil))
        #expect(Policy.isPresent(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: true))
        #expect(!Policy.isPresent(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: false))
        #expect(Policy.isPresent(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: true))
        #expect(Policy.isPresent(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: nil))
        #expect(!Policy.isPresent(allowedBySettings: false, scrollerStyle: .legacy, hasScrollback: true))
    }
}
