import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5887.
///
/// `NSWindow.cmux_performKeyEquivalent(with:)` force-dispatches certain key
/// events straight into the focused responder's `keyDown(with:)`. When the
/// responder does not consume the key, AppKit can route the very same event
/// back into `performKeyEquivalent` while the first dispatch is still on the
/// stack (WebKit replays unhandled keys through the responder chain, and on
/// macOS 26 `-[NSWindow keyDown:]` re-enters `performKeyEquivalent`). Without
/// a replay guard at the dispatch chokepoint the event ping-pongs forever and
/// overflows the main-thread stack.
@MainActor
final class WindowKeyDownReplayGuardTests: XCTestCase {

    /// First responder stub that models the re-entrant AppKit behavior: an
    /// unhandled keyDown flows back into `NSWindow.performKeyEquivalent` with
    /// the exact same event while the original dispatch is still on the stack.
    /// Bounded so the pre-fix failure mode is a clean assertion failure
    /// instead of a stack overflow.
    private final class ReplayingKeyDownView: NSView {
        private(set) var keyDownEvents: [NSEvent] = []
        var replaysRemaining = 5

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            keyDownEvents.append(event)
            guard replaysRemaining > 0 else { return }
            replaysRemaining -= 1
            _ = window?.performKeyEquivalent(with: event)
        }
    }

    private func makeWindowWithReplayingResponder() -> (NSWindow, ReplayingKeyDownView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let responder = ReplayingKeyDownView(frame: NSRect(x: 0, y: 0, width: 64, height: 32))
        container.addSubview(responder)
        XCTAssertTrue(window.makeFirstResponder(responder))
        return (window, responder)
    }

    /// Option+A producing printable text ("å"). The printable-Option-text
    /// bypass in `cmux_performKeyEquivalent` force-dispatches this into the
    /// first responder's `keyDown`, which is the unguarded dispatch the
    /// https://github.com/manaflow-ai/cmux/issues/5887 crash looped through.
    private func makeOptionTextKeyDownEvent(
        windowNumber: Int,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            characters: "å",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )
    }

    func testPrintableOptionTextKeyDownIsForceDispatchedExactlyOncePerEvent() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let (window, responder) = makeWindowWithReplayingResponder()
        guard let event = makeOptionTextKeyDownEvent(windowNumber: window.windowNumber) else {
            XCTFail("Failed to construct Option+A key event")
            return
        }

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(
            responder.keyDownEvents.count,
            1,
            "The same in-flight key event must not be force-dispatched into keyDown again " +
            "while the first dispatch is still on the stack; unbounded re-dispatch is the " +
            "infinite key-routing loop from " +
            "https://github.com/manaflow-ai/cmux/issues/5887"
        )
    }

    func testDistinctKeyDownEventsAreEachForceDispatched() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let (window, responder) = makeWindowWithReplayingResponder()
        responder.replaysRemaining = 0

        let baseTimestamp = ProcessInfo.processInfo.systemUptime
        guard
            let first = makeOptionTextKeyDownEvent(
                windowNumber: window.windowNumber,
                timestamp: baseTimestamp
            ),
            let second = makeOptionTextKeyDownEvent(
                windowNumber: window.windowNumber,
                timestamp: baseTimestamp + 0.05
            )
        else {
            XCTFail("Failed to construct Option+A key events")
            return
        }

        // Distinct events (key autorepeat, repeat typing) must each be
        // force-dispatched; the replay guard is per-event, not a throttle.
        XCTAssertTrue(window.performKeyEquivalent(with: first))
        XCTAssertTrue(window.performKeyEquivalent(with: second))
        XCTAssertEqual(responder.keyDownEvents.count, 2)
    }

    func testSameEventIsForceDispatchedAgainAfterPriorDispatchUnwinds() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let (window, responder) = makeWindowWithReplayingResponder()
        responder.replaysRemaining = 0

        guard let event = makeOptionTextKeyDownEvent(windowNumber: window.windowNumber) else {
            XCTFail("Failed to construct Option+A key event")
            return
        }

        // WebKit legitimately re-sends an unhandled key event through
        // NSApp.sendEvent after the original dispatch has fully unwound. The
        // guard is stack-scoped, so the same event must dispatch again here.
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(responder.keyDownEvents.count, 2)
    }
}
