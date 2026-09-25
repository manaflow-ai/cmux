import AppKit
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TmuxWorkspacePaneOverlayRenderState {
    /// Preserves legacy overlay fixtures inside the test target while keeping
    /// every production construction explicit about the configured color.
    init(
        workspaceId: UUID,
        unreadRects: [CGRect],
        flashRect: CGRect?,
        activePaneBorderRect: CGRect? = nil,
        activePaneBorderColorHex: String? = nil,
        flashToken: UInt64,
        flashReason: WorkspaceAttentionFlashReason?
    ) {
        self.init(
            workspaceId: workspaceId,
            unreadRects: unreadRects,
            flashRect: flashRect,
            activePaneBorderRect: activePaneBorderRect,
            activePaneBorderColorHex: activePaneBorderColorHex,
            flashToken: flashToken,
            flashReason: flashReason,
            workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: nil)
        )
    }
}

@Suite("tmux workspace pane overlay model")
struct TmuxWorkspacePaneOverlayModelTests {
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
                flashReason: nil,
                workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: nil)
            )
        )
        overlayHostingView.frame = ordinaryHostingView.frame
        overlayHostingView.additionalSafeAreaInsets = inset

        #expect(ordinaryHostingView.safeAreaInsets.top == inset.top)
        #expect(ordinaryHostingView.safeAreaRect.minY == inset.top)
        #expect(overlayHostingView.safeAreaInsets == NSEdgeInsetsZero)
        #expect(overlayHostingView.safeAreaRect == overlayHostingView.bounds)
    }

    @Test @MainActor
    func tracksActivePaneBorder() {
        let model = TmuxWorkspacePaneOverlayModel()
        let borderRect = CGRect(x: 8, y: 12, width: 320, height: 180)
        let attentionColor = WorkspaceAttentionColor(configuredHex: "#FF69B4")

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: nil,
            activePaneBorderRect: borderRect,
            activePaneBorderColorHex: "#33AAFF",
            flashToken: 0,
            flashReason: nil,
            workspaceAttentionColor: attentionColor
        ))

        #expect(model.activePaneBorderRect == borderRect)
        #expect(model.activePaneBorderColorHex == "#33AAFF")
        #expect(model.workspaceAttentionColor == attentionColor)

        model.clear()

        #expect(model.activePaneBorderRect == nil)
        #expect(model.activePaneBorderColorHex == nil)
        #expect(model.workspaceAttentionColor == WorkspaceAttentionColor(configuredHex: nil))
    }
}
