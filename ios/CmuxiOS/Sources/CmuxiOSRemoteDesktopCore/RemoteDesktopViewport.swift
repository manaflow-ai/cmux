public import CmuxRemoteDesktop
public import CoreGraphics

/// The phone's lens on a remote target (c3-rd.md 4): the target fit into
/// the screen at zoom 1, pinch zoom around a focal point, a center that the
/// trackpad cursor drags along, and the mapping between screen points and
/// target pixels. View state only; the Mac never sees it except as the
/// `desktop.view` request it produces.
public struct RemoteDesktopViewport: Hashable, Sendable {
    /// Most screen points per target pixel at full zoom.
    public static let maxPointsPerPixel = 4.0

    public private(set) var bounds: CGSize
    public private(set) var targetWidth: Double
    public private(set) var targetHeight: Double
    /// 1 shows the whole target.
    public private(set) var zoom: Double = 1
    /// The target point at the middle of the screen.
    public private(set) var center: CGPoint

    public init(bounds: CGSize, target: DesktopTargetInfo) {
        self.bounds = bounds
        targetWidth = Double(max(1, target.width))
        targetHeight = Double(max(1, target.height))
        center = CGPoint(x: targetWidth / 2, y: targetHeight / 2)
    }

    /// Screen points per target pixel at zoom 1.
    public var fitScale: Double {
        min(Double(bounds.width) / targetWidth, Double(bounds.height) / targetHeight)
    }

    /// Screen points per target pixel now.
    public var scale: Double { fitScale * zoom }

    public var maxZoom: Double { max(1, Self.maxPointsPerPixel / max(fitScale, 0.0001)) }

    /// The part of the target on screen, in target pixels.
    public var visibleRect: CGRect {
        let width = Self.snap(min(targetWidth, Double(bounds.width) / scale), to: targetWidth)
        let height = Self.snap(min(targetHeight, Double(bounds.height) / scale), to: targetHeight)
        let x = Self.snap(Self.snap(center.x - width / 2, to: 0), to: targetWidth - width)
        let y = Self.snap(Self.snap(center.y - height / 2, to: 0), to: targetHeight - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Floating point noise from the fit math must not shave a pixel off.
    private static func snap(_ value: Double, to edge: Double) -> Double {
        abs(value - edge) < 1e-6 ? edge : value
    }

    public func targetPoint(forScreen point: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (point.x - bounds.width / 2) / scale, y: center.y + (point.y - bounds.height / 2) / scale)
    }

    public func screenPoint(forTarget point: CGPoint) -> CGPoint {
        CGPoint(x: bounds.width / 2 + (point.x - center.x) * scale, y: bounds.height / 2 + (point.y - center.y) * scale)
    }

    /// Where to draw a frame encoded for `view` (its rect in target pixels).
    public func screenRect(for view: DesktopView) -> CGRect {
        let origin = screenPoint(forTarget: CGPoint(x: view.rect.x, y: view.rect.y))
        return CGRect(x: origin.x, y: origin.y, width: Double(view.rect.width) * scale, height: Double(view.rect.height) * scale)
    }

    public mutating func setBounds(_ size: CGSize) {
        bounds = size
        clampCenter()
    }

    /// The target changed size (VNC resize, display switch): back to fit.
    public mutating func setTarget(_ target: DesktopTargetInfo) {
        targetWidth = Double(max(1, target.width))
        targetHeight = Double(max(1, target.height))
        zoom = 1
        center = CGPoint(x: targetWidth / 2, y: targetHeight / 2)
    }

    /// Multiplies the zoom, keeping the target point under `focus` still.
    public mutating func pinch(by factor: Double, around focus: CGPoint) {
        let anchor = targetPoint(forScreen: focus)
        zoom = min(max(zoom * factor, 1), maxZoom)
        center = CGPoint(x: anchor.x - (focus.x - bounds.width / 2) / scale, y: anchor.y - (focus.y - bounds.height / 2) / scale)
        clampCenter()
    }

    /// Moves the lens by a screen-point delta (content follows the finger).
    public mutating func pan(by delta: CGPoint) {
        center = CGPoint(x: center.x - delta.x / scale, y: center.y - delta.y / scale)
        clampCenter()
    }

    /// Keeps `point` (target pixels) inside the lens with a margin, moving
    /// the lens when the trackpad cursor reaches an edge.
    public mutating func follow(_ point: CGPoint, margin: Double = 24) {
        let visible = visibleRect
        let inset = margin / scale
        var dx = 0.0
        var dy = 0.0
        if point.x < visible.minX + inset { dx = point.x - (visible.minX + inset) }
        if point.x > visible.maxX - inset { dx = point.x - (visible.maxX - inset) }
        if point.y < visible.minY + inset { dy = point.y - (visible.minY + inset) }
        if point.y > visible.maxY - inset { dy = point.y - (visible.maxY - inset) }
        guard dx != 0 || dy != 0 else { return }
        center = CGPoint(x: center.x + dx, y: center.y + dy)
        clampCenter()
    }

    /// The `desktop.view` request for what is on screen: the visible rect
    /// (whole pixels) at the screen's backing pixels.
    public func viewRequest(screenScale: Double) -> (rect: DesktopRect, pixelWidth: Int, pixelHeight: Int) {
        let visible = visibleRect.integral
        let rect = DesktopRect(x: Int(visible.minX), y: Int(visible.minY), width: Int(visible.width), height: Int(visible.height))
        let onScreen = CGSize(width: visible.width * scale, height: visible.height * scale)
        return (rect, Int((onScreen.width * screenScale).rounded()), Int((onScreen.height * screenScale).rounded()))
    }

    private mutating func clampCenter() {
        let visible = visibleRect
        let halfWidth = visible.width / 2
        let halfHeight = visible.height / 2
        center.x = min(max(center.x, halfWidth), targetWidth - halfWidth)
        center.y = min(max(center.y, halfHeight), targetHeight - halfHeight)
    }
}
