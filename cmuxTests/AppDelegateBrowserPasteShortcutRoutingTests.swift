import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class BrowserPasteShortcutFocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
@Suite(.serialized)
struct AppDelegateBrowserPasteShortcutRoutingTests {
    @Test func browserPasteCommandRoutesThroughWebContentFirst() throws {
        let pasteEvent = try #require(makeKeyEvent(
            modifierFlags: [.command],
            characters: "v",
            charactersIgnoringModifiers: "v",
            keyCode: 9
        ))

        #expect(
            shouldRouteBrowserDocumentEditingCommandEquivalentThroughWebContentFirst(pasteEvent),
            "Cmd+V should preflight into focused browser web content like copy/cut/select-all"
        )
    }

    @Test func textBoxDeclinesPasteShortcutWhenNotFirstResponder() throws {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostWindow.animationBehavior = .none
        hostWindow.isReleasedWhenClosed = false
        defer {
            hostWindow.orderOut(nil)
            hostWindow.close()
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let otherView = BrowserPasteShortcutFocusableTestView(frame: NSRect(x: 0, y: 40, width: 320, height: 40))
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textBoxScrollView.documentView = textView
        contentView.addSubview(otherView)
        contentView.addSubview(textBoxScrollView)
        hostWindow.contentView = contentView
        hostWindow.makeKeyAndOrderFront(nil)

        #expect(hostWindow.makeFirstResponder(otherView))
        #expect(hostWindow.firstResponder === otherView)

        let pasteEvent = try #require(makeKeyEvent(
            modifierFlags: [.command],
            characters: "v",
            charactersIgnoringModifiers: "v",
            keyCode: 9
        ))

        #expect(
            !textView.performKeyEquivalent(with: pasteEvent),
            "Text box must not claim Cmd+V while another view owns first responder"
        )
    }

    @Test func textBoxHandlesPasteShortcutWhenFirstResponder() throws {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostWindow.animationBehavior = .none
        hostWindow.isReleasedWhenClosed = false
        defer {
            hostWindow.orderOut(nil)
            hostWindow.close()
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textBoxScrollView.documentView = textView
        contentView.addSubview(textBoxScrollView)
        hostWindow.contentView = contentView
        hostWindow.makeKeyAndOrderFront(nil)

        #expect(hostWindow.makeFirstResponder(textView))
        #expect(hostWindow.firstResponder === textView)

        let pasteEvent = try #require(makeKeyEvent(
            modifierFlags: [.command],
            characters: "v",
            charactersIgnoringModifiers: "v",
            keyCode: 9
        ))

        #expect(
            textView.performKeyEquivalent(with: pasteEvent),
            "Text box must still handle Cmd+V while it owns first responder"
        )
    }

    @Test func browserPlainTextPasteCommandIsNotADocumentEditingPaste() throws {
        let pasteAsPlainTextEvent = try #require(makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "v",
            charactersIgnoringModifiers: "v",
            keyCode: 9
        ))

        #expect(
            !shouldRouteBrowserDocumentEditingCommandEquivalentThroughWebContentFirst(pasteAsPlainTextEvent),
            "Cmd+Shift+V keeps its dedicated paste-as-plain-text path"
        )
    }

    private func makeKeyEvent(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
