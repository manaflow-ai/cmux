import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("window tmux workspace pane overlay controller")
struct WindowTmuxWorkspacePaneOverlayControllerTests {
    @Test @MainActor
    func overlayHostingViewIgnoresWindowSafeArea() {
        let inset = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        let ordinaryHostingView = NSHostingView(rootView: Color.clear)
        ordinaryHostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        ordinaryHostingView.additionalSafeAreaInsets = inset

        let overlayHostingView = TmuxWorkspacePaneOverlayHostingView(
            rootView: TmuxWorkspacePaneOverlayView(
                unreadRects: [],
                flashRect: nil,
                activePaneBorderRect: nil,
                activePaneBorderColorHex: nil,
                flashStartedAt: nil,
                flashReason: nil
            )
        )
        overlayHostingView.frame = ordinaryHostingView.frame
        overlayHostingView.additionalSafeAreaInsets = inset

        #expect(ordinaryHostingView.safeAreaInsets.top == inset.top)
        #expect(ordinaryHostingView.safeAreaRect.minY == inset.top)
        #expect(overlayHostingView.safeAreaInsets == NSEdgeInsetsZero)
        #expect(overlayHostingView.safeAreaRect == overlayHostingView.bounds)
    }
}
