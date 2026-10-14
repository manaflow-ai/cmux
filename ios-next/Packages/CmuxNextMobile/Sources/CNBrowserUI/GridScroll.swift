#if os(iOS)
import Observation
import SwiftUI

/// The tab grid's scroll position, written on every scroll frame.
///
/// Held by reference so a scroll frame invalidates only the views that read
/// it (the zoom while it runs, `GridFollowOffset`), not the browser screen
/// and every card: as `@State` values on the screen, each scroll frame
/// re-evaluated the screen, the grid and all of its cards (device trace,
/// Tabs grid scroll: 4 ms per frame of SwiftUI updates, 12 frames over 8 ms).
@MainActor
@Observable
final class GridScrollTracker {
    /// Scroll offset (content offset plus the top inset).
    var offset: CGFloat = 0
    /// Origin of the grid's scroll content in the screen's coordinate space
    /// (nil until the grid has reported it).
    var contentOrigin: CGPoint?

    /// Where content point (0, 0) is on screen now.
    var screenOrigin: CGPoint { contentOrigin ?? CGPoint(x: 0, y: -offset) }
}

/// Places a view at `origin`: screen coordinates, or grid content
/// coordinates moved with the grid's scroll when `scroll` is set. Only this
/// modifier reads the scroll position, so the view it wraps (the live
/// terminal card) is not rebuilt on a scroll frame.
struct GridFollowOffset: ViewModifier {
    var origin: CGPoint
    var scroll: GridScrollTracker?

    func body(content: Content) -> some View {
        let base = scroll?.screenOrigin ?? .zero
        content.offset(x: origin.x + base.x, y: origin.y + base.y)
    }
}
#endif
