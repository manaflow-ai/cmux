import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for https://github.com/manaflow-ai/cmux chromium omnibar
// autofocus: on a blank `.chromium` surface, `BrowserPanel.focus()` must leave
// first responder with the omnibar (WebKit parity) instead of stealing it into
// the chromium content view. Runs against a DEBUG-injected stand-in content
// view, so no Content Shell process is required. The suite is @MainActor with
// no suspension points, so no `.serialized` is needed.
@MainActor
@Suite("Chromium blank-surface omnibar focus")
struct BrowserPanelChromiumBlankOmnibarFocusTests {
    private final class FakeChromiumContentView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct Harness {
        let window: NSWindow
        let omnibarField: NSTextField
        let chromiumView: FakeChromiumContentView

        func tearDown() {
            window.orderOut(nil)
        }
    }

    private func makeHarness(panel: BrowserPanel) -> Harness {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let omnibarField = NSTextField(frame: NSRect(x: 20, y: 380, width: 600, height: 24))
        contentView.addSubview(omnibarField)

        let chromiumView = FakeChromiumContentView(frame: NSRect(x: 20, y: 20, width: 600, height: 340))
        contentView.addSubview(chromiumView)
        panel.chromiumWebContentViewOverrideForTesting = chromiumView

        window.makeKeyAndOrderFront(nil)
        return Harness(window: window, omnibarField: omnibarField, chromiumView: chromiumView)
    }

    @Test func blankSurfaceFocusLeavesFirstResponderWithOmnibar() {
        let panel = BrowserPanel(workspaceId: UUID(), engineKind: .chromium)
        let harness = makeHarness(panel: panel)
        defer { harness.tearDown() }

        #expect(harness.window.makeFirstResponder(harness.omnibarField))
        let responderBeforeFocus = harness.window.firstResponder

        panel.focus()

        #expect(harness.window.firstResponder !== harness.chromiumView)
        #expect(harness.window.firstResponder === responderBeforeFocus)
    }

    @Test func loadedSurfaceFocusMovesFirstResponderToWebContent() {
        let panel = BrowserPanel(workspaceId: UUID(), engineKind: .chromium)
        let harness = makeHarness(panel: panel)
        defer { harness.tearDown() }

        // Chromium navigation without a live session records the URL and defers
        // the load; the surface is no longer blank for omnibar purposes.
        panel.navigate(to: URL(string: "https://example.com/")!)

        #expect(harness.window.makeFirstResponder(harness.omnibarField))

        panel.focus()

        #expect(harness.window.firstResponder === harness.chromiumView)
    }
}
