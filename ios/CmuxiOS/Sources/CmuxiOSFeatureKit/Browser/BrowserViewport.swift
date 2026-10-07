/// The phone viewport the Mac encodes for (c2-browser-stream.md section 3).
public struct BrowserViewport: Hashable, Sendable {
    /// Points.
    public var width: Int
    public var height: Int
    /// Screen scale (3 on most iPhones).
    public var scale: Double
    /// 1, or 2 while the local zoom lens is above 1.5x (sharper encode).
    public var zoomBucket: Int
    public var refreshHz: Int

    public init(width: Int, height: Int, scale: Double, zoomBucket: Int = 1, refreshHz: Int = 60) {
        self.width = width
        self.height = height
        self.scale = scale
        self.zoomBucket = zoomBucket
        self.refreshHz = refreshHz
    }
}
