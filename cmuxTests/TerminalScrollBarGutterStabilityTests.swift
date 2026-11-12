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

        /// Hosts a fresh pane in a 640pt-wide window laid out with `scrollerStyle`.
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
            // The scroll view derives its style from "Show scroll bars"; model
            // the setting that selects `scrollerStyle` on this scroll view only,
            // so the test is the same on every Mac.
            let scrollView = hostedView.subviews.compactMap { $0 as? GhosttyScrollView }.first
            let preference = scrollerStyle == .legacy ? "Always" : "WhenScrolling"
            scrollView?.showScrollBarsPreference = { preference }
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

    @Test("Automatic keeps the overlay scroller when AppKit resolves legacy")
    func automaticIgnoresAppKitLegacyResolution() throws {
        let harness = Harness(scrollerStyle: .overlay)
        let scrollView = try #require(harness.hostedView.subviews.compactMap { $0 as? GhosttyScrollView }.first)
        scrollView.showScrollBarsPreference = { "Automatic" }

        // A mouse becomes the only pointing device: AppKit writes legacy into
        // every scroll view and posts the preference change.
        scrollView.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        harness.hostedView.layoutSubtreeIfNeeded()

        #expect(scrollView.scrollerStyle == .overlay)
        #expect(harness.contentWidth(after: Self.emptyHistory) == harness.paneWidth, "Automatic reserved a legacy gutter")
        #expect(harness.contentWidth(after: Self.withHistory) == harness.paneWidth)
    }

    @Test("AppKit's legacy scroller remains visible")
    func legacyPresentationRespectsAppKit() throws {
        // "Show scroll bars: Always" selects legacy. Once selected, AppKit
        // owns its presentation. Pin only this scroll view's style so
        // concurrent tests retain the process's unmodified preferences.
        let harness = Harness(scrollerStyle: .legacy)
        let scrollView = try #require(harness.hostedView.subviews.compactMap { $0 as? GhosttyScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let width = harness.contentWidth(after: Self.withHistory)
        #expect(scroller.alphaValue == 1, "Do not hide the legacy scrollbar AppKit selected")
        #expect(harness.contentWidth(after: Self.emptyHistory) == width)
        #expect(scroller.alphaValue == 1)
        #expect(scrollView.scrollerStyle == .legacy)
    }

    @Test("Unrelated defaults notifications do not reconcile terminal geometry")
    func unrelatedDefaultsLeavePendingLayoutAlone() {
        let harness = Harness(scrollerStyle: .legacy)
        // Model a pending pane layout. A defaults notification must not apply
        // the full geometry path and resize the terminal before layout does.
        harness.hostedView.surfaceView.frame.size.width -= 20
        let pendingFrame = harness.hostedView.surfaceView.frame

        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )

        #expect(harness.hostedView.surfaceView.frame == pendingFrame)
    }
}
