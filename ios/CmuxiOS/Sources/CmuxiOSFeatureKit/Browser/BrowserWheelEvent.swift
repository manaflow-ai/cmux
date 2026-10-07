/// A precise scroll in page CSS pixels with its gesture phases.
public struct BrowserWheelEvent: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var dx: Double
    public var dy: Double
    public var phase: BrowserGesturePhase
    public var momentumPhase: BrowserGesturePhase

    public init(x: Double, y: Double, dx: Double, dy: Double, phase: BrowserGesturePhase, momentumPhase: BrowserGesturePhase = .none) {
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
        self.phase = phase
        self.momentumPhase = momentumPhase
    }
}
