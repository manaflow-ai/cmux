import Foundation
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
    func tracksCustomPaneBorders() {
        let model = TmuxWorkspacePaneOverlayModel()
        let border = TmuxWorkspacePaneColorBorder(
            rect: CGRect(x: 4, y: 8, width: 200, height: 120),
            colorHex: "#7A4FD8"
        )

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: nil,
            customPaneBorders: [border],
            flashToken: 0,
            flashReason: nil
        ))

        #expect(model.customPaneBorders == [border])

        model.clear()

        #expect(model.customPaneBorders.isEmpty)
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

    @Test @MainActor
    func activePaneBorderDrawsAboveCustomColor() {
        let model = TmuxWorkspacePaneOverlayModel()
        let sharedRect = CGRect(x: 8, y: 12, width: 320, height: 180)
        let customBorder = TmuxWorkspacePaneColorBorder(
            rect: sharedRect,
            colorHex: "#6A1B9A"
        )
        let activeBorder = TmuxWorkspacePaneColorBorder(
            rect: sharedRect,
            colorHex: "#33AAFF"
        )

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: nil,
            customPaneBorders: [customBorder],
            activePaneBorderRect: activeBorder.rect,
            activePaneBorderColorHex: activeBorder.colorHex,
            flashToken: 0,
            flashReason: nil
        ))

        #expect(model.paneBordersInDrawOrder == [customBorder, activeBorder])
    }
}
