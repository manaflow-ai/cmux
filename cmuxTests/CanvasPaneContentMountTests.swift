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
    @Test func terminalAttachesToContainerBeforeBecomingVisible() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let hostedView = NSView(frame: .zero)
        var visibilityWasRequested = false

        CanvasPaneContentMount.attachTerminalView(hostedView, to: container) { attachedView in
            visibilityWasRequested = true
            #expect(attachedView.superview === container)
        }

        #expect(visibilityWasRequested)
        #expect(hostedView.superview === container)
    }
}
