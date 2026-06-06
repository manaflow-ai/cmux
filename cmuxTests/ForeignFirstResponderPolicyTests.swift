import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for ``shouldRespectForeignFirstResponder(_:in:isRightSidebarOwner:)`` — the policy that
/// decides whether an active terminal yields to the window's current first responder or reclaims
/// focus. Text editors are always respected (the user is typing into them, and they may be hosted in
/// an overlay window); non-text focus owners must belong to the window, preserving the #5269 recovery
/// path for stranded hosts.
@MainActor
@Suite struct ForeignFirstResponderPolicyTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    private let neverSidebarOwner: (NSResponder) -> Bool = { _ in false }
    private let alwaysSidebarOwner: (NSResponder) -> Bool = { _ in true }

    @Test func respectsInWindowTextEditor() {
        let window = makeWindow()
        let textView = NSTextView(frame: .zero)
        window.contentView?.addSubview(textView)
        #expect(shouldRespectForeignFirstResponder(textView, in: window, isRightSidebarOwner: neverSidebarOwner))
    }

    /// A text editor is respected even when its backing window differs from the policy window. SwiftUI
    /// hosts a popover/palette overlay's field editor in a separate window while it is still the main
    /// window's active first responder; the terminal must yield the keystroke. (Terminal surfaces, the
    /// real subject of the #5269 stranding guard, are excluded by callers before this policy.)
    @Test func respectsTextEditorHostedInAnotherWindow() {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let textView = NSTextView(frame: .zero)
        windowB.contentView?.addSubview(textView) // hosted in windowB's hierarchy (e.g. an overlay)
        #expect(shouldRespectForeignFirstResponder(textView, in: windowA, isRightSidebarOwner: neverSidebarOwner))
    }

    @Test func respectsInWindowRightSidebarOwner() {
        let window = makeWindow()
        let view = NSView(frame: .zero)
        window.contentView?.addSubview(view)
        #expect(shouldRespectForeignFirstResponder(view, in: window, isRightSidebarOwner: alwaysSidebarOwner))
    }

    /// The #5269 regression for the sidebar/dock flavor: a sidebar host stranded in another window
    /// must NOT be respected. Without the window-membership check this returns `true`.
    @Test func reclaimsFromStrandedRightSidebarOwner() {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let view = NSView(frame: .zero)
        windowB.contentView?.addSubview(view)
        #expect(!shouldRespectForeignFirstResponder(view, in: windowA, isRightSidebarOwner: alwaysSidebarOwner))
    }

    /// A non-text responder detached from any window is reclaimed (it is neither a real text editor
    /// being typed into nor an in-window focus owner), preserving the #5269 recovery path.
    @Test func reclaimsFromDetachedNonTextResponder() {
        let window = makeWindow()
        let view = NSView(frame: .zero) // never added to a window -> .window is nil
        #expect(!shouldRespectForeignFirstResponder(view, in: window, isRightSidebarOwner: alwaysSidebarOwner))
    }

    @Test func doesNotRespectPlainInWindowView() {
        let window = makeWindow()
        let view = NSView(frame: .zero)
        window.contentView?.addSubview(view)
        // Neither a text editor nor a sidebar owner: the terminal reclaims focus (existing behavior).
        #expect(!shouldRespectForeignFirstResponder(view, in: window, isRightSidebarOwner: neverSidebarOwner))
    }
}
