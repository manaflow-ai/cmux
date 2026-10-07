public import CmuxBrowserStream
public import CoreGraphics

/// The trackpad-mode cursor (c3-rd.md 3): finger deltas move it in target
/// pixels with pointer acceleration, clamped to the target. The phone draws
/// it locally, so it moves without waiting for the Mac.
public struct TrackpadPointer: Hashable, Sendable {
    public private(set) var position: CGPoint
    public private(set) var width: Double
    public private(set) var height: Double

    public init(width: Int, height: Int) {
        self.width = Double(max(1, width))
        self.height = Double(max(1, height))
        position = CGPoint(x: self.width / 2, y: self.height / 2)
    }

    public mutating func resize(width: Int, height: Int) {
        self.width = Double(max(1, width))
        self.height = Double(max(1, height))
        position = CGPoint(x: min(position.x, self.width - 1), y: min(position.y, self.height - 1))
    }

    /// Gain for a finger speed in screen points per second: precise when
    /// slow, up to 3x for fast flicks.
    public static func acceleration(speed: Double) -> Double {
        1 + min(max(speed - 200, 0) / 600, 2)
    }

    /// Moves by a screen delta at `speed`; `scale` is screen points per
    /// target pixel. Returns the rd event for the new position.
    public mutating func move(by delta: CGPoint, speed: Double, scale: Double) -> RdInputEvent {
        let gain = Self.acceleration(speed: speed) / max(scale, 0.0001)
        return moveTo(CGPoint(x: position.x + delta.x * gain, y: position.y + delta.y * gain))
    }

    /// Jumps to a target point (direct mode, hover).
    public mutating func moveTo(_ point: CGPoint) -> RdInputEvent {
        position = CGPoint(x: min(max(point.x, 0), width - 1), y: min(max(point.y, 0), height - 1))
        return .pointer(x: Int32(position.x.rounded(.down)), y: Int32(position.y.rounded(.down)))
    }
}
