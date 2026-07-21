import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Canvas pane content mount")
struct CanvasPaneContentMountTests {
    @Test func terminalAttachesToWindowBeforeBecomingVisible() {
        let panel = TerminalPanel(workspaceId: UUID())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        var visibilityWasRequested = false

        let mount = CanvasPaneContentMount(
            content: .terminal(panel, .disabled),
            panelId: panel.id,
            container: container,
            onFocusPanel: { _ in },
            makeTerminalVisible: { hostedView in
                visibilityWasRequested = true
                #expect(hostedView.superview === container)
                #expect(hostedView.window === window)
            }
        )
        defer {
            mount.unmount()
            panel.surface.teardownSurface()
            window.contentView = nil
            window.close()
        }

        #expect(visibilityWasRequested)
        #expect(panel.hostedView.superview === container)
    }
}
