public import CoreGraphics

/// Maps between the phone view and the streamed Mac page under fit width,
/// the local zoom lens and its pan (view state only; the Mac never sees the
/// lens except as a sharper encode bucket).
public struct BrowserViewportTransform: Hashable, Sendable {
    public var viewSize: CGSize
    /// The Mac page viewport in CSS pixels.
    public var pageSize: CGSize
    /// Local lens zoom, at least 1.
    public var zoom: CGFloat
    /// Lens pan in view points, clamped so the page covers the view.
    public var pan: CGPoint

    public static let maxZoom: CGFloat = 4

    public init(viewSize: CGSize, pageSize: CGSize, zoom: CGFloat = 1, pan: CGPoint = .zero) {
        self.viewSize = viewSize
        self.pageSize = pageSize
        self.zoom = min(max(zoom, 1), Self.maxZoom)
        self.pan = pan
        self.pan = clamped(pan)
    }

    /// Scale that fits the page width into the view.
    public var fitScale: CGFloat {
        guard viewSize.width > 0, pageSize.width > 0 else { return 1 }
        return viewSize.width / pageSize.width
    }

    /// The page rectangle in view coordinates (top-aligned, centered horizontally).
    public var pageRect: CGRect {
        let scale = fitScale * zoom
        return CGRect(x: -pan.x, y: -pan.y, width: pageSize.width * scale, height: pageSize.height * scale)
    }

    /// The page point under a view point, or nil outside the page.
    public func pagePoint(fromView point: CGPoint) -> CGPoint? {
        let rect = pageRect
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width * pageSize.width,
                       y: (point.y - rect.minY) / rect.height * pageSize.height)
    }

    /// A view-space finger delta in page CSS pixels (scroll distance).
    public func pageDelta(fromView delta: CGPoint) -> CGPoint {
        let scale = max(fitScale * zoom, .leastNonzeroMagnitude)
        return CGPoint(x: delta.x / scale, y: delta.y / scale)
    }

    /// Zooms around a view point, keeping the page point under it fixed.
    public func zoomed(to newZoom: CGFloat, around anchor: CGPoint) -> BrowserViewportTransform {
        let target = min(max(newZoom, 1), Self.maxZoom)
        let ratio = target / zoom
        let pan = CGPoint(x: (anchor.x + self.pan.x) * ratio - anchor.x, y: (anchor.y + self.pan.y) * ratio - anchor.y)
        return BrowserViewportTransform(viewSize: viewSize, pageSize: pageSize, zoom: target, pan: pan)
    }

    public func panned(by delta: CGPoint) -> BrowserViewportTransform {
        BrowserViewportTransform(viewSize: viewSize, pageSize: pageSize, zoom: zoom,
                                 pan: CGPoint(x: pan.x - delta.x, y: pan.y - delta.y))
    }

    /// 2 while the lens is above 1.5x (the Mac encodes sharper), else 1.
    public var zoomBucket: Int { zoom > 1.5 ? 2 : 1 }

    private func clamped(_ pan: CGPoint) -> CGPoint {
        let scale = fitScale * zoom
        let width = pageSize.width * scale
        let height = pageSize.height * scale
        let maxX = max(0, width - viewSize.width)
        let maxY = max(0, height - viewSize.height)
        return CGPoint(x: min(max(pan.x, 0), maxX), y: min(max(pan.y, 0), maxY))
    }
}
