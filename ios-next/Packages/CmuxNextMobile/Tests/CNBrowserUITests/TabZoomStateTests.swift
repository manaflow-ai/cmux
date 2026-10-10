@testable import CNBrowserUI
import Testing

struct TabZoomStateTests {
    private func run(_ s: inout TabZoomState, seconds: Double) {
        var t = 0.0
        while t < seconds {
            s.step(1.0 / 60)
            t += 1.0 / 60
        }
    }

    @Test func opensAndClosesAndSettles() {
        var s = TabZoomState()
        #expect(s.pageInteractive && !s.gridInteractive)
        s.go(toOverview: true)
        #expect(s.phase == .animating && !s.pageInteractive && !s.gridInteractive)
        run(&s, seconds: 1)
        #expect(s.phase == .overview && s.progress == 1 && s.gridInteractive)
        s.go(toOverview: false)
        run(&s, seconds: 1)
        #expect(s.phase == .page && s.progress == 0 && s.pageInteractive)
    }

    /// The freeze: after (+), opening the new tab and going back to the grid,
    /// repeated, the grid must always end up interactive.
    @Test func repeatedNewTabAndBackNeverLeavesTheGridBlocked() {
        var s = TabZoomState(overview: true)
        for i in 0..<20 {
            s.start(from: 1, toOverview: false)  // (+)
            run(&s, seconds: Double(i % 3) * 0.1)  // sometimes interrupted early
            s.go(toOverview: true)  // tabs button
            run(&s, seconds: 1.2)
            #expect(s.phase == .overview, "iteration \(i)")
            #expect(s.gridInteractive, "iteration \(i)")
        }
    }

    @Test func reversingMidwayKeepsPositionAndAFifthOfTheVelocity() {
        var s = TabZoomState()
        s.go(toOverview: true)
        run(&s, seconds: 0.13)
        let p = s.progress, v = s.velocity
        #expect(p > 0.3 && p < 0.9 && v > 0)
        s.go(toOverview: false)
        #expect(s.progress == p)
        #expect(abs(s.velocity - v * TabZoomState.velocityKeptOnReversal) < 1e-9)
        #expect(s.target == 0 && s.spring == .reversal)
        run(&s, seconds: 1.2)
        #expect(s.phase == .page && s.pageInteractive)
    }

    @Test func repeatedTogglesDuringAnimationAlwaysSettle() {
        var s = TabZoomState()
        for i in 0..<30 {
            s.go(toOverview: i % 2 == 0)
            run(&s, seconds: 0.05)
        }
        run(&s, seconds: 1.5)
        #expect(s.phase == .page || s.phase == .overview)
        #expect(s.gridInteractive != s.pageInteractive)
    }

    @Test func pinchCompletesPastHalfOrWithVelocityElseSpringsBack() {
        var s = TabZoomState()
        s.beginInteraction()
        s.updateInteraction(progress: 0.3, velocity: 0.2)
        #expect(s.endInteraction(velocity: 0.2, startedFromOverview: false) == false)
        run(&s, seconds: 1.2)
        #expect(s.phase == .page)

        s.beginInteraction()
        s.updateInteraction(progress: 0.3, velocity: 2)
        #expect(s.endInteraction(velocity: 2, startedFromOverview: false) == true)
        run(&s, seconds: 1.2)
        #expect(s.phase == .overview)

        s.beginInteraction()
        s.updateInteraction(progress: 0.7, velocity: 0)
        #expect(s.endInteraction(velocity: 0, startedFromOverview: true) == true)
        run(&s, seconds: 1.2)
        #expect(s.phase == .overview && s.gridInteractive)
    }

    @Test func toggleDuringPinchHandsOffWithVelocity() {
        var s = TabZoomState()
        s.beginInteraction()
        s.updateInteraction(progress: 0.4, velocity: 1)
        s.go(toOverview: true)
        #expect(s.phase == .animating && s.velocity == 1)
        run(&s, seconds: 1.2)
        #expect(s.phase == .overview)
    }
}
