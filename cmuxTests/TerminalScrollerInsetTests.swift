import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for https://github.com/manaflow-ai/cmux/issues/1082 and
/// https://github.com/manaflow-ai/cmux/issues/2997. A persistent vertical
/// scroller rendered on top of the rightmost terminal column because the
/// surface width passed to libghostty did not account for the scroller gutter.
/// The terminal reserves the inset only when macOS is going to render a
/// persistent (legacy) scroller; transient overlay scrollers that fade out
/// keep the full terminal width.
final class TerminalScrollerInsetTests: XCTestCase {
    func testReservesNothingWhenScrollerIsAbsent() {
        let inset = GhosttySurfaceScrollView.verticalScrollerInsetWidth(
            hasVerticalScroller: false,
            preferredScrollerStyle: .legacy,
            scrollerWidth: 15
        )
        XCTAssertEqual(inset, 0)
    }

    func testReservesNothingForTransientOverlayScrollers() {
        // Trackpad / transient-overlay case: scroller fades out when idle, so
        // briefly overlapping content during scroll is acceptable in exchange
        // for keeping the full terminal width.
        let inset = GhosttySurfaceScrollView.verticalScrollerInsetWidth(
            hasVerticalScroller: true,
            preferredScrollerStyle: .overlay,
            scrollerWidth: 15
        )
        XCTAssertEqual(inset, 0)
    }

    func testReservesScrollerWidthForPersistentLegacyScrollers() {
        // macOS reports legacy when "Show scroll bars" is Always, or Automatic
        // with a mouse attached — in both cases the scroller is permanently
        // visible, so we must shrink the terminal surface by its width.
        let inset = GhosttySurfaceScrollView.verticalScrollerInsetWidth(
            hasVerticalScroller: true,
            preferredScrollerStyle: .legacy,
            scrollerWidth: 15
        )
        XCTAssertEqual(inset, 15)
    }

    func testClampsNegativeScrollerWidthToZero() {
        let inset = GhosttySurfaceScrollView.verticalScrollerInsetWidth(
            hasVerticalScroller: true,
            preferredScrollerStyle: .legacy,
            scrollerWidth: -4
        )
        XCTAssertEqual(inset, 0)
    }
}
