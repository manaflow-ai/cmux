import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("content view pane overlay geometry")
struct ContentViewWindowResizeTests {
    @Test @MainActor
    func windowOverlayConvertsCompleteStateIntoDrawingCoordinates() throws {
        _ = NSApplication.shared

        let contentView = NSHostingView(rootView: Color.clear)
        contentView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        defer { window.close() }

        let referenceBoundsOffset = CGPoint(x: 12, y: 20)
        contentView.bounds.origin = referenceBoundsOffset
        #expect(contentView.isFlipped)

        let paneView = NSView(frame: NSRect(x: 100, y: 500, width: 600, height: 220))
        contentView.addSubview(paneView)

        let controller = try #require(
            WindowTmuxWorkspacePaneOverlayController.controller(
                for: window,
                createIfNeeded: true
            )
        )

        let referenceRect = ContentView.tmuxWorkspacePaneExactRect(
            for: paneView,
            in: contentView
        )
        let sourceRect = try #require(referenceRect)
        let sourceState = TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [sourceRect],
            flashRect: sourceRect,
            activePaneBorderRect: sourceRect,
            activePaneBorderColorHex: "#3A7F77",
            flashToken: 1,
            flashReason: .debug
        )
        let renderState = try #require(
            controller.renderStateInOverlayCoordinates(sourceState)
        )
        let expectedDrawingRect = sourceRect.offsetBy(
            dx: -referenceBoundsOffset.x,
            dy: -referenceBoundsOffset.y
        )

        #expect(referenceRect == paneView.frame)
        #expect(renderState.unreadRects == [expectedDrawingRect])
        #expect(renderState.flashRect == expectedDrawingRect)
        #expect(renderState.activePaneBorderRect == expectedDrawingRect)
        #expect(renderState.activePaneBorderColorHex == sourceState.activePaneBorderColorHex)
        #expect(renderState.flashToken == sourceState.flashToken)
        #expect(renderState.flashReason == sourceState.flashReason)
    }
}
