import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Zoomable split viewport")
struct ZoomableSplitViewportTests {
    @Test func zoomOutClampsAtExactFit() {
        let root = makeRoot()
        defer { root.teardown() }

        root.setViewport(center: CGPoint(x: 400, y: 250), magnification: 0.25)

        #expect(abs(root.currentMagnification - 1.0) < 0.0001)
        root.zoom(by: 0.5)
        #expect(abs(root.currentMagnification - 1.0) < 0.0001)
    }

    @Test func zoomInRemainsAvailableBeyondFit() {
        let root = makeRoot()
        defer { root.teardown() }

        root.zoom(by: 1.25)

        #expect(abs(root.currentMagnification - 1.25) < 0.0001)
    }

    private func makeRoot() -> ZoomableSplitRootView {
        let root = ZoomableSplitRootView(
            workspace: Workspace(title: "Zoomable split tests"),
            isWorkspaceInputActive: false,
            content: AnyView(Color.clear)
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        root.frame = host.bounds
        host.addSubview(root)
        host.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        return root
    }
}
