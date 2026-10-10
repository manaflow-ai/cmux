import CNCore
import CoreGraphics

/// Geometry of the panes canvas: every Mac workspace as a region, stacked
/// vertically under a small title, its panes placed by their normalized
/// rects. A workspace is scaled to the phone's width; when that would make
/// a pane narrower than `minPaneWidth` (or shorter than `minPaneHeight`) the
/// workspace grows past the screen in that direction, so wide layouts extend
/// horizontally and the canvas scrolls both ways.
struct PaneCanvasLayout: Equatable, Sendable {
    struct Region: Equatable, Sendable {
        var workspaceId: String
        var title: String
        /// Title row frame (content coordinates).
        var titleFrame: CGRect
        /// Workspace frame (content coordinates).
        var frame: CGRect
        /// Pane card frames (content coordinates), by pane id.
        var panes: [String: CGRect]
    }

    static let inset: CGFloat = 16
    static let titleHeight: CGFloat = 28
    static let regionGap: CGFloat = 20
    static let paneGap: CGFloat = 6
    static let minPaneWidth: CGFloat = 150
    static let minPaneHeight: CGFloat = 190
    /// The Mac window's shape when the layout gives none (16:10).
    static let workspaceAspect: CGFloat = 10.0 / 16.0

    var regions: [Region] = []
    var contentSize: CGSize = .zero

    init() {}

    /// `top`: content y of the first title (below the top controls);
    /// `bottom`: space kept under the last workspace (the bottom bar).
    init(layout: MacLayout, width: CGFloat, top: CGFloat, bottom: CGFloat) {
        var y = top
        var maxX = width
        let base = max(1, width - 2 * Self.inset)
        for ws in layout.workspaces where !ws.panes.isEmpty {
            var w = base
            var h = base * Self.workspaceAspect
            for p in ws.panes {
                if p.rect.w > 0 { w = max(w, (Self.minPaneWidth + Self.paneGap) / CGFloat(p.rect.w)) }
                if p.rect.h > 0 { h = max(h, (Self.minPaneHeight + Self.paneGap) / CGFloat(p.rect.h)) }
            }
            let titleFrame = CGRect(x: Self.inset, y: y, width: base, height: Self.titleHeight)
            let frame = CGRect(x: Self.inset, y: titleFrame.maxY, width: w, height: h)
            var panes: [String: CGRect] = [:]
            for p in ws.panes {
                let r = CGRect(x: frame.minX + CGFloat(p.rect.x) * w, y: frame.minY + CGFloat(p.rect.y) * h,
                               width: CGFloat(p.rect.w) * w, height: CGFloat(p.rect.h) * h)
                // Gaps between neighbors: inset every edge by half a gap,
                // except edges on the workspace's border.
                let g = Self.paneGap / 2
                let left = p.rect.x > 0.0001 ? g : 0
                let top = p.rect.y > 0.0001 ? g : 0
                let right = p.rect.x + p.rect.w < 0.9999 ? g : 0
                let bottomInset = p.rect.y + p.rect.h < 0.9999 ? g : 0
                panes[p.id] = CGRect(x: r.minX + left, y: r.minY + top, width: r.width - left - right, height: r.height - top - bottomInset)
            }
            regions.append(Region(workspaceId: ws.id, title: ws.title, titleFrame: titleFrame, frame: frame, panes: panes))
            y = frame.maxY + Self.regionGap
            maxX = max(maxX, frame.maxX + Self.inset)
        }
        contentSize = CGSize(width: maxX, height: y - Self.regionGap + bottom)
    }

    func paneFrame(_ paneId: String) -> CGRect? {
        for r in regions { if let f = r.panes[paneId] { return f } }
        return nil
    }

    /// Scroll offset that keeps `current` when the pane is fully inside the
    /// visible area, else brings the pane in with the least movement per axis.
    func offset(revealing paneId: String, from current: CGPoint, viewport: CGSize, topInset: CGFloat, bottomInset: CGFloat) -> CGPoint {
        guard let f = paneFrame(paneId) else { return current }
        let maxX = max(0, contentSize.width - viewport.width)
        let maxY = max(0, contentSize.height - viewport.height)
        var x = current.x, y = current.y
        if f.minX - x < 0 { x = f.minX - Self.inset } else if f.maxX - x > viewport.width { x = f.maxX - viewport.width + Self.inset }
        let visibleTop = topInset, visibleBottom = viewport.height - bottomInset
        if f.minY - y < visibleTop { y = f.minY - visibleTop } else if f.maxY - y > visibleBottom { y = f.maxY - visibleBottom }
        return CGPoint(x: min(maxX, max(0, x)), y: min(maxY, max(0, y)))
    }
}

/// Press-and-hold state for one pane's tab picker.
struct PaneTabPickerState: Equatable {
    var paneId: String
    var tabs: [LayoutTab]
    /// The pane's card on screen when the hold began (cards grow from it).
    var paneFrame: CGRect
    /// The tab under the center, fractional while sliding (0 = first tab).
    var position: CGFloat
    /// The tab focused when the hold began.
    var startIndex: Int
    /// Finger still down from the press: horizontal travel scrubs.
    var holding = true
    /// Finger travel exceeded the slop since the hold began.
    var moved = false
    /// A tab was picked: the cards are gone (the zoom carries it).
    var launched = false

    var index: Int { min(max(0, Int(position.rounded())), max(0, tabs.count - 1)) }

    /// Points of finger travel per tab while scrubbing.
    static let scrubPitch: CGFloat = 72
    static let slop: CGFloat = 8

    /// Position for `dx` of finger travel from `base` (finger left = next
    /// tab), with a rubber band past the first and last tab.
    static func position(base: Int, dx: CGFloat, pitch: CGFloat, count: Int) -> CGFloat {
        let raw = CGFloat(base) - dx / pitch
        let last = CGFloat(max(0, count - 1))
        if raw < 0 { return -rubber(-raw) }
        if raw > last { return last + rubber(raw - last) }
        return raw
    }

    private static func rubber(_ over: CGFloat) -> CGFloat { 0.35 * over / (1 + over) }
}

/// Geometry of the picker: large centered cards in page proportions,
/// neighbors peeking on both sides.
struct PaneTabPickerLayout {
    var size: CGSize
    var safeTop: CGFloat

    var cardWidth: CGFloat { min(340, (size.width * 0.7).rounded()) }
    var cardHeight: CGFloat { min(size.height * 0.58, (cardWidth * size.height / max(1, size.width)).rounded()) }
    var pitch: CGFloat { cardWidth + 18 }
    var center: CGRect {
        CGRect(x: (size.width - cardWidth) / 2, y: max(safeTop + 70, (size.height - cardHeight) / 2 - 24), width: cardWidth, height: cardHeight)
    }

    /// Card `k`'s frame at `shown` (0 = folded into the pane, 1 = open).
    func card(_ k: Int, position: CGFloat, shown: CGFloat, pane: CGRect) -> CGRect {
        let open = center.offsetBy(dx: (CGFloat(k) - position) * pitch, dy: 0)
        return CGRect(x: pane.minX + (open.minX - pane.minX) * shown, y: pane.minY + (open.minY - pane.minY) * shown,
                      width: pane.width + (open.width - pane.width) * shown, height: pane.height + (open.height - pane.height) * shown)
    }
}
