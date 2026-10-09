public import CoreGraphics
import Foundation

/// Mac click counts from successive taps: a double tap is a double click
/// (word selection), a triple tap a triple click. Taps go out at once with
/// a rising count, so a single tap never waits for a double-tap timeout.
public struct BrowserTapClickCounter: Hashable, Sendable {
    public var chainInterval: TimeInterval
    public var chainRadius: CGFloat
    private var lastTime: TimeInterval?
    private var lastLocation: CGPoint?
    private var count = 0

    public init(chainInterval: TimeInterval = 0.45, chainRadius: CGFloat = 28) {
        self.chainInterval = chainInterval
        self.chainRadius = chainRadius
    }

    public mutating func register(at location: CGPoint, time: TimeInterval) -> Int {
        if let lastTime, let lastLocation, time - lastTime <= chainInterval,
           hypot(location.x - lastLocation.x, location.y - lastLocation.y) <= chainRadius {
            count = min(count + 1, 3)
        } else {
            count = 1
        }
        lastTime = time
        lastLocation = location
        return count
    }
}
