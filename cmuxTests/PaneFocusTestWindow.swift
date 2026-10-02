import AppKit

/// Models a responder that temporarily cannot take focus, without replacing
/// the panel's real AppKit views or exposing production-only test hooks.
@MainActor
final class PaneFocusTestWindow: NSWindow {
    weak var rejectedFirstResponder: NSResponder?
    /// Deterministic destination for tests that resign a field editor. AppKit
    /// otherwise chooses the window's next key view when passed `nil`, which
    /// can be the very responder the test is intentionally rejecting.
    weak var resignationDestination: NSResponder?
    private(set) var rejectedFocusAttempts = 0

    func resetRejectedFocusAttempts() {
        rejectedFocusAttempts = 0
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder == nil, let resignationDestination {
            return super.makeFirstResponder(resignationDestination)
        }
        if let rejectedFirstResponder, responder === rejectedFirstResponder {
            rejectedFocusAttempts += 1
            return false
        }
        return super.makeFirstResponder(responder)
    }
}
