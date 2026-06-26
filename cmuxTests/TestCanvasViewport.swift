import AppKit
import CmuxCanvasUI
import Foundation

@MainActor
final class TestCanvasViewport: CanvasViewportControlling {
    var renderedPanelIds: Set<UUID>

    init(renderedPanelIds: Set<UUID>) {
        self.renderedPanelIds = renderedPanelIds
    }

    func revealPane(_ panelId: UUID, animated: Bool) {}

    func toggleOverview() {}

    func zoom(by factor: CGFloat) {}

    func resetZoom() {}

    func setViewport(center: CGPoint, magnification: CGFloat?) {}

    var currentMagnification: CGFloat { 1 }

    var currentCenterInCanvas: CGPoint { .zero }

    func modelDidChangeExternally(animated: Bool) {}
}
