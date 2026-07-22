import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("content view window resize")
struct ContentViewWindowResizeTests {
    @Test @MainActor
    func paneOverlayRectMatchesVisiblePaneAfterWindowShrink() throws {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let contentView = try #require(window.contentView)
        let paneView = NSView(frame: NSRect(x: 120, y: 48, width: 300, height: 352))
        contentView.addSubview(paneView)

        window.setContentSize(NSSize(width: 250, height: 250))
        contentView.layoutSubtreeIfNeeded()

        #expect(
            ContentView.tmuxWorkspacePaneExactRect(for: paneView, in: contentView)
                == CGRect(x: 120, y: 48, width: 130, height: 202)
        )
    }
}
