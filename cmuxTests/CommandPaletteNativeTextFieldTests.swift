import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct CommandPaletteNativeTextFieldTests {
    @Test
    func pendingFocusRequestIsAppliedWhenPanelBecomesKey() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let field = CommandPaletteNativeTextField(frame: NSRect(x: 20, y: 260, width: 440, height: 24))
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(field)
        _ = window.makeFirstResponder(nil)

        field.requestsFirstResponder = true
        #expect(window.firstResponder !== field)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(window.firstResponder === field || field.currentEditor() != nil)
    }

    @Test
    func cancelledFocusRequestDoesNotApplyWhenPanelBecomesKey() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let field = CommandPaletteNativeTextField(frame: NSRect(x: 20, y: 260, width: 440, height: 24))
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(field)
        field.requestsFirstResponder = true
        field.requestsFirstResponder = false

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(window.firstResponder !== field)
        #expect(field.currentEditor() == nil)
    }
}
