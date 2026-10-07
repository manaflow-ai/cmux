import CmuxTerminalRenderCore
import CoreGraphics

/// Touch state of one terminal view (client view state, never sent).
struct TerminalGestureState {
    /// The pan translation already sent as scroll.
    var scrolledTranslation: CGFloat = 0
    /// Deceleration after a scroll, stepped by the frame link.
    var momentum: TerminalScrollMomentum?
    /// The zoom when the current pinch began.
    var pinchStartZoom: Double = 1
    /// Ghostty opened a link during the current tap.
    var openedLink = false
    /// The link under the last synthesized pointer position, if any.
    var hoveredLink: String?
    /// A long-press selection is being dragged.
    var selecting = false
}
