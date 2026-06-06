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

    /// A text editor hosted in a *child* window of the policy window is respected. SwiftUI hosts a
    /// popover/palette overlay's field editor in a separate `_NSPopoverWindow` whose `parent` chain
    /// reaches the main window (verified at runtime), even though it is the main window's active first
    /// responder; the strict `.window === window` guard rejected it and keyRepair stole the keystroke.
    @Test func respectsTextEditorInChildPopoverWindow() {
        let host = makeWindow()
        let popover = makeWindow()
        host.addChildWindow(popover, ordered: .above) // popover.parent === host, like an NSPopover window
        let textView = NSTextView(frame: .zero)
        popover.contentView?.addSubview(textView)
        #expect(shouldRespectForeignFirstResponder(textView, in: host, isRightSidebarOwner: neverSidebarOwner))
    }

    /// A text editor stranded in an *unrelated* window (not the policy window and not a child it
    /// presents) is reclaimed, so a field reparented into another cmux window cannot block the terminal
    /// from recovering keyboard focus (issue #5269).
    @Test func reclaimsFromTextEditorInUnrelatedWindow() {
        let windowA = makeWindow()
        let windowB = makeWindow() // not a child of windowA
        let textView = NSTextView(frame: .zero)
        windowB.contentView?.addSubview(textView)
        #expect(!shouldRespectForeignFirstResponder(textView, in: windowA, isRightSidebarOwner: neverSidebarOwner))
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

    /// A *detached* text editor (no backing window, e.g. a removed field left as first responder) is
    /// reclaimed: the overlay exception requires a non-nil window, so a stale editor cannot permanently
    /// block terminal focus recovery (issue #5269).
    @Test func reclaimsFromDetachedTextEditor() {
        let window = makeWindow()
        let textView = NSTextView(frame: .zero) // never added to a window -> .window is nil
        #expect(!shouldRespectForeignFirstResponder(textView, in: window, isRightSidebarOwner: neverSidebarOwner))
    }

    @Test func doesNotRespectPlainInWindowView() {
        let window = makeWindow()
        let view = NSView(frame: .zero)
        window.contentView?.addSubview(view)
        // Neither a text editor nor a sidebar owner: the terminal reclaims focus (existing behavior).
        #expect(!shouldRespectForeignFirstResponder(view, in: window, isRightSidebarOwner: neverSidebarOwner))
    }
}
