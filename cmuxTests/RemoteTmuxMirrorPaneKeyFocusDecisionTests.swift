import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pins the pure policy behind establishing key focus on a freshly created
/// mirror pane. The mirror drives focus from the control-stream event that
/// makes the pane active; the view may not have reached its presentation
/// window yet, so the policy decides between focusing now, (re-)arming the
/// attach hook (`onDidAttachToWindow`), and dropping the intent. Waiting is
/// only allowed for states that end in another attach edge (unattached, or
/// parked in the surface's offscreen bootstrap window); a final attachment
/// that cannot take focus cancels instead, so no stale intent survives to
/// steal focus later. The decision is a pure function of the guard inputs,
/// so the table below covers it without a live window or run loop.
@MainActor
@Suite
struct RemoteTmuxMirrorPaneKeyFocusDecisionTests {

    private typealias Decision = RemoteTmuxWindowMirror.PaneKeyFocusDecision

    private static func decide(
        mirrorAlive: Bool = true,
        paneStillActive: Bool = true,
        mirrorOnScreen: Bool = true,
        viewInWindow: Bool = true,
        inParkingWindow: Bool = false,
        viewVisibleInUI: Bool = true,
        windowIsKey: Bool = true,
        responderYields: Bool = true
    ) -> Decision {
        RemoteTmuxWindowMirror.paneKeyFocusDecision(
            mirrorAlive: mirrorAlive,
            paneStillActive: paneStillActive,
            mirrorOnScreen: mirrorOnScreen,
            viewInWindow: viewInWindow,
            inParkingWindow: inParkingWindow,
            viewVisibleInUI: viewVisibleInUI,
            windowIsKey: windowIsKey,
            responderYields: responderYields
        )
    }

    @Test("pane presented in a visible key window is focused immediately")
    func focusesMountedPane() {
        #expect(Self.decide() == .focusNow)
    }

    @Test("unattached pane waits for the attach edge instead of a timer")
    func waitsForMount() {
        #expect(Self.decide(viewInWindow: false) == .waitForMount)
        // The key/visibility reads of a detached view are meaningless; only
        // the attach edge can make them real.
        #expect(Self.decide(viewInWindow: false, viewVisibleInUI: false, windowIsKey: false)
            == .waitForMount)
    }

    @Test("an attach into the parking window re-arms for the presentation attach")
    func parkingWindowWaits() {
        // Portal churn routes views through the surface's offscreen bootstrap
        // window; consuming the intent there would strand the freshly split
        // pane unfocused. Waiting is live, not stale: leaving the parking
        // window for the presentation window fires viewDidMoveToWindow again.
        #expect(Self.decide(inParkingWindow: true, windowIsKey: false) == .waitForMount)
        #expect(Self.decide(inParkingWindow: true, viewVisibleInUI: false, windowIsKey: false)
            == .waitForMount)
    }

    @Test("a final attach into a non-key or hidden window cancels, not waits")
    func nonKeyFinalAttachmentCancels() {
        // A real window that is not key (or a hidden host) has no attach edge
        // left to wait on; keeping the intent alive would let it fire much
        // later and steal focus.
        #expect(Self.decide(windowIsKey: false) == .skip)
        #expect(Self.decide(viewVisibleInUI: false) == .skip)
    }

    @Test("a pane switch cancels the pending focus")
    func paneSwitchCancels() {
        #expect(Self.decide(paneStillActive: false, viewInWindow: false) == .skip)
        #expect(Self.decide(paneStillActive: false) == .skip)
    }

    @Test("a dead or torn-down mirror never moves the responder")
    func tornDownSkips() {
        #expect(Self.decide(mirrorAlive: false) == .skip)
        #expect(Self.decide(mirrorAlive: false, viewInWindow: false) == .skip)
    }

    @Test("a background or headless mirror never moves the responder")
    func backgroundSkips() {
        #expect(Self.decide(mirrorOnScreen: false) == .skip)
        #expect(Self.decide(mirrorOnScreen: false, viewInWindow: false) == .skip)
    }

    @Test("a foreign first responder cancels instead of being robbed")
    func foreignResponderCancels() {
        // The user focused a search field or palette after the split; a late
        // mount must not pull focus out of it.
        #expect(Self.decide(responderYields: false) == .skip)
    }

    @Test("the foreign-responder read only decides at presentation time")
    func foreignResponderIgnoredWhileUnpresented() {
        // An unattached or parked view reads some other window's responder
        // state (or none at all); the check is deferred to focus time.
        #expect(Self.decide(viewInWindow: false, responderYields: false) == .waitForMount)
        #expect(Self.decide(inParkingWindow: true, windowIsKey: false, responderYields: false)
            == .waitForMount)
    }
}
