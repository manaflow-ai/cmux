// The CoreGraphics geometry cmux's iOS logic uses, for the Linux harness (scripts/ios-linux-harness.sh).
// Foundation on Linux already has CGFloat, CGPoint, CGSize and CGRect; this module re-exports it under
// the CoreGraphics name and adds the one geometry type it lacks. No drawing, contexts or colors.
@_exported import Foundation

public struct CGVector: Hashable, Sendable, Codable {
    public var dx: CGFloat
    public var dy: CGFloat

    public init() {
        dx = 0
        dy = 0
    }

    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }

    public init(dx: Double, dy: Double) {
        self.dx = CGFloat(dx)
        self.dy = CGFloat(dy)
    }

    public init(dx: Int, dy: Int) {
        self.dx = CGFloat(dx)
        self.dy = CGFloat(dy)
    }

    public static var zero: CGVector { CGVector() }
}
