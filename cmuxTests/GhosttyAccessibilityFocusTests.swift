import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Ghostty accessibility focus", .serialized)
struct GhosttyAccessibilityFocusTests {
    @Test("switching terminal first responder moves accessibility focus")
    func switchingTerminalFirstResponderMovesAccessibilityFocus() throws {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try #require(window.contentView)
        let firstTerminal = GhosttyNSView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 240)
        )
        let secondTerminal = GhosttyNSView(
            frame: NSRect(x: 200, y: 0, width: 200, height: 240)
        )
        contentView.addSubview(firstTerminal)
        contentView.addSubview(secondTerminal)
        window.makeKeyAndOrderFront(nil)

        #expect(firstTerminal.isAccessibilityElement())
        #expect(firstTerminal.accessibilityRole() == .textArea)
        #expect(window.makeFirstResponder(firstTerminal))
        #expect(window.firstResponder === firstTerminal)
        #expect(
            firstTerminal.isAccessibilityFocused(),
            "The AXTextArea that owns keyboard focus must report AXFocused"
        )
        #expect(!secondTerminal.isAccessibilityFocused())

        #expect(window.makeFirstResponder(secondTerminal))
        #expect(window.firstResponder === secondTerminal)
        #expect(!firstTerminal.isAccessibilityFocused())
        #expect(
            secondTerminal.isAccessibilityFocused(),
            "Accessibility focus must follow keyboard focus when switching terminal panes"
        )
    }
}
