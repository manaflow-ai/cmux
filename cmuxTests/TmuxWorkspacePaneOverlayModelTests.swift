import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: nil,
            activePaneBorderRect: borderRect,
            activePaneBorderColorHex: "#33AAFF",
            flashToken: 0,
            flashReason: nil
        ))

        #expect(model.activePaneBorderRect == borderRect)
        #expect(model.activePaneBorderColorHex == "#33AAFF")

        model.clear()

        #expect(model.activePaneBorderRect == nil)
        #expect(model.activePaneBorderColorHex == nil)
    }
}
