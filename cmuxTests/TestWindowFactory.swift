import AppKit

// The only place in cmuxTests that constructs a window.
//
// An NSWindow built in code has `isReleasedWhenClosed = true` by default, and `-[NSWindow close]`
// defers a release into the autorelease pool. ARC also owns the local reference and releases it at
// scope exit. That is two releases against one retain, so the pool drain touches freed memory:
// SIGSEGV in `objc_release` under `objc_autoreleasePoolPop`, which kills the test host rather than
// failing a test, and a dead host loses every verdict it had pending.
//
// `scripts/lint-test-window-construction.py` fails any other file in the test targets that
// constructs a window.
//
// This is a function and not an NSWindow subclass because a subclass inherits the designated
// initializer, so every call site would emit `initWithContentRect:styleMask:backing:defer:` into its
// own object file, and the object-file half of that check could not tell a call site from a
// construction.
enum TestWindow {
    static let defaultContentRect = NSRect(x: 0, y: 0, width: 320, height: 240)

    /// A window the test owns outright: closing it releases nothing ARC still holds.
    ///
    /// `animationBehavior` is `.none` because a window's appearance animation can outlive it and go
    /// on committing CoreAnimation transactions off the main thread, which wedges a suite.
    static func make(
        contentRect: NSRect = TestWindow.defaultContentRect,
        styleMask: NSWindow.StyleMask = [.titled, .closable],
        backing: NSWindow.BackingStoreType = .buffered,
        defer deferCreation: Bool = false
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: deferCreation
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }

    /// A window hosting `view`, sized to it. Most callers want this rather than `make`.
    static func hosting(
        _ view: NSView,
        styleMask: NSWindow.StyleMask = [.titled, .closable]
    ) -> NSWindow {
        let window = make(
            contentRect: view.bounds.isEmpty ? TestWindow.defaultContentRect : view.bounds,
            styleMask: styleMask
        )
        window.contentView = view
        return window
    }
}
