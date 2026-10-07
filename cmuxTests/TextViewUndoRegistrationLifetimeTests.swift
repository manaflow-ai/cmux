import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the `NSApplication.cmux_sendAction` →
/// `-[NSUndoManager undoNestedGroup]` crash family
/// (https://manaflow.sentry.io/issues/7524703308/,
/// https://manaflow.sentry.io/issues/7466338842/,
/// https://manaflow.sentry.io/issues/7538651325/,
/// https://manaflow.sentry.io/issues/7724897382/).
///
/// AppKit registers text edits as `_undoRedoTextOperation:` on the text
/// view's `NSTextStorage` in whatever undo manager the view resolves, usually
/// the window's shared one. Undo managers do not retain their targets, and
/// AppKit leaves those registrations behind when the text view leaves its
/// window. Edit > Undo in a surviving editor then messages the departed
/// view's storage, which crashes once that storage is freed.

/// Window delegate that supplies an explicitly grouped undo manager so each
/// edit is its own undo group, independent of run-loop event grouping.
private final class ExplicitUndoWindowDelegate: NSObject, NSWindowDelegate {
    let undoManager: UndoManager = {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }()

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        undoManager
    }
}

@MainActor
@Suite(.serialized)
struct TextViewUndoRegistrationLifetimeTests {
    private func makeWindow(delegate: ExplicitUndoWindowDelegate) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        return window
    }

    private func makeEditableTextView(y: CGFloat) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: y, width: 200, height: 40))
        textView.isEditable = true
        textView.allowsUndo = true
        return textView
    }

    /// Types `text` into `textView` as one closed undo group.
    private func type(
        _ text: String,
        into textView: NSTextView,
        window: NSWindow,
        undoManager: UndoManager
    ) {
        #expect(window.makeFirstResponder(textView))
        undoManager.beginUndoGrouping()
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.breakUndoCoalescing()
        undoManager.endUndoGrouping()
    }

    @Test
    func editMenuUndoDoesNotReachATextViewThatLeftTheWindow() throws {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let delegate = ExplicitUndoWindowDelegate()
        let window = makeWindow(delegate: delegate)
        defer { window.close() }
        let contentView = try #require(window.contentView)
        let survivor = makeEditableTextView(y: 0)
        let departed = makeEditableTextView(y: 60)
        contentView.addSubview(survivor)
        contentView.addSubview(departed)

        type("kept", into: survivor, window: window, undoManager: delegate.undoManager)
        type("closed", into: departed, window: window, undoManager: delegate.undoManager)
        #expect(departed.undoManager === delegate.undoManager)

        #expect(window.makeFirstResponder(survivor))
        departed.removeFromSuperview()

        // Edit > Undo resolves `undo:` through the responder chain to the
        // window, exactly like the menu item and its Cmd+Z key equivalent.
        #expect(survivor.tryToPerform(Selector(("undo:")), with: nil))

        #expect(departed.string == "closed")
        #expect(survivor.string == "")
        #expect(!delegate.undoManager.canUndo)
    }

    @Test
    func movingATextViewToAnotherWindowDropsItsRegistrationsFromThePreviousWindow() throws {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let firstDelegate = ExplicitUndoWindowDelegate()
        let firstWindow = makeWindow(delegate: firstDelegate)
        let secondDelegate = ExplicitUndoWindowDelegate()
        let secondWindow = makeWindow(delegate: secondDelegate)
        defer {
            firstWindow.close()
            secondWindow.close()
        }
        let textView = makeEditableTextView(y: 0)
        try #require(firstWindow.contentView).addSubview(textView)

        type("draft", into: textView, window: firstWindow, undoManager: firstDelegate.undoManager)
        #expect(firstDelegate.undoManager.canUndo)

        try #require(secondWindow.contentView).addSubview(textView)

        #expect(textView.window === secondWindow)
        #expect(!firstDelegate.undoManager.canUndo)
        #expect(textView.string == "draft")
    }
}
