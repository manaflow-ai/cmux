import Foundation

/// A normalized pane rectangle used for local directional focus math.
public struct CmuxLayoutRect: Sendable, Equatable {
    /// The leading horizontal coordinate.
    public let x: Double

    /// The top vertical coordinate.
    public let y: Double

    /// The horizontal extent.
    public let width: Double

    /// The vertical extent.
    public let height: Double

    /// Creates a layout rectangle.
    /// - Parameters:
    ///   - x: The leading horizontal coordinate.
    ///   - y: The top vertical coordinate.
    ///   - width: The horizontal extent.
    ///   - height: The vertical extent.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
