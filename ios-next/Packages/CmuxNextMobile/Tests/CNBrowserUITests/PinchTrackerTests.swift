@testable import CNBrowserUI
import CoreGraphics
import Testing

private let full = CGRect(x: 0, y: 0, width: 440, height: 956)
private let card = CGRect(x: 228, y: 244, width: 196, height: 276)
private let path = ZoomRectPath(full: full, card: card)

struct PinchTrackerTests {
    /// Inside the page..card range the rect is the start width times the
    /// pinch scale and the page point under the start centroid stays under
    /// the centroid, to well under a point.
    @Test(arguments: [0.98, 0.9, 0.75, 0.6, 0.5])
    func tracksScaleAndCentroidOneToOne(scale: CGFloat) {
        let start = CGPoint(x: 220, y: 520)
        let t = PinchTracker(startRect: full, startCentroid: start)
        let centroid = CGPoint(x: 170, y: 430)
        let s = t.state(scale: scale, centroid: centroid, path: path)
        let rect = path.rect(progress: s.progress, offset: s.offset)
        #expect(abs(rect.width - full.width * scale) < 0.01)
        let a = t.anchor
        #expect(abs(rect.minX + a.x * rect.width - centroid.x) < 0.01)
        #expect(abs(rect.minY + a.y * rect.height - centroid.y) < 0.01)
    }

    @Test func rubberBandsPastTheCardAndPastThePage() {
        let t = PinchTracker(startRect: full, startCentroid: CGPoint(x: 220, y: 478))
        let tiny = t.state(scale: 0.2, centroid: CGPoint(x: 220, y: 478), path: path)
        #expect(tiny.progress > 1 && tiny.progress < 1 + PinchTracker.bandBeyondCard)
        let big = t.state(scale: 1.6, centroid: CGPoint(x: 220, y: 478), path: path)
        #expect(big.progress < 0 && big.progress > -PinchTracker.bandBeyondPage)
        // Diminishing returns: equal finger steps move less and less.
        let a = t.state(scale: 0.4, centroid: .zero, path: path).progress
        let b = t.state(scale: 0.3, centroid: .zero, path: path).progress
        let c = t.state(scale: 0.2, centroid: .zero, path: path).progress
        #expect(b - a > c - b)
    }

    /// The release keeps every velocity component: the spring starts from the
    /// tracked state with the tracked velocity.
    @Test func releaseHasNoVelocityDiscontinuity() {
        var s = TabZoomState()
        s.beginInteraction()
        s.updateInteraction(progress: 0.6, offset: CGVector(dx: -40, dy: 25), velocity: 1.8, offsetVelocity: CGVector(dx: -300, dy: 120))
        s.release(toOverview: true)
        #expect(s.progress == 0.6 && s.velocity == 1.8)
        #expect(s.offset == CGVector(dx: -40, dy: 25) && s.offsetVelocity == CGVector(dx: -300, dy: 120))
        // One small step continues in the same direction at about the same speed.
        s.step(1.0 / 240)
        #expect(s.progress > 0.6 && abs(s.velocity - 1.8) < 0.6)
        #expect(s.offset.dx < -40)
        var t = 0.0
        while t < 1.5 { s.step(1.0 / 120); t += 1.0 / 120 }
        #expect(s.phase == .overview && s.offset == .zero)
    }

    /// A pinch that lands during a running zoom grabs it where it is.
    @Test func grabbingARunningZoomDoesNotJump() {
        var s = TabZoomState()
        s.go(toOverview: true)
        for _ in 0..<8 { s.step(1.0 / 60) }
        let before = path.rect(progress: s.progress, offset: s.offset)
        s.beginInteraction()
        let t = PinchTracker(startRect: before, startCentroid: CGPoint(x: before.midX, y: before.midY))
        let g = t.state(scale: 1, centroid: CGPoint(x: before.midX, y: before.midY), path: path)
        s.updateInteraction(progress: g.progress, offset: g.offset, velocity: 0, offsetVelocity: .zero)
        let after = path.rect(progress: s.progress, offset: s.offset)
        #expect(abs(after.minX - before.minX) < 0.01 && abs(after.minY - before.minY) < 0.01)
        #expect(abs(after.width - before.width) < 0.01)
    }

    @Test func releaseDecision() {
        #expect(PinchTracker.releaseToOverview(progress: 0.5, velocity: 0, startedFromOverview: false, path: path))
        #expect(!PinchTracker.releaseToOverview(progress: 0.2, velocity: 0, startedFromOverview: false, path: path))
        #expect(PinchTracker.releaseToOverview(progress: 0.2, velocity: 3, startedFromOverview: false, path: path))
        #expect(!PinchTracker.releaseToOverview(progress: 0.8, velocity: -3, startedFromOverview: true, path: path))
        #expect(PinchTracker.releaseToOverview(progress: 0.9, velocity: 0, startedFromOverview: true, path: path))
    }
}
