@testable import CNBrowserUI
import CoreGraphics
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
            s.openNewTab()  // (+)
            run(&s, seconds: Double(i % 3) * 0.1)  // sometimes interrupted early
            s.go(toOverview: true)  // tabs button
            run(&s, seconds: 1.2)
            #expect(s.phase == .overview, "iteration \(i)")
            #expect(s.gridInteractive, "iteration \(i)")
        }
    }

    private func timeTo(_ level: Double, _ s: inout TabZoomState) -> Double {
        var t = 0.0
        while s.progress > level, t < 1 {
            s.step(1.0 / 600)
            t += 1.0 / 600
        }
        return t * 1000
    }

    /// (+): Safari's start page grows on 0.27 / 1.03 from the first frame.
    @Test func newTabUsesSafarisSpring() {
        var s = TabZoomState(overview: true)
        s.openNewTab()
        #expect(s.phase == .animating && s.spring == .newTab)
        #expect(s.spring.response == 0.27 && s.spring.damping == 1.03)
        // An existing tab opens on toPage.
        var o = TabZoomState(overview: true)
        o.go(toOverview: false)
        #expect(o.spring == .toPage)
    }

    /// The last tab closed: the page replays Safari's curve and settles
    /// when it ends.
    @Test func lastTabStartPageReplaysSafari() {
        var s = TabZoomState(overview: true)
        s.openNewTab(spring: .afterLastClose)
        #expect(s.curve == .lastTab)
        run(&s, seconds: SafariCurve.lastTab.duration + 0.02)
        #expect(s.phase == .page)
    }

    @Test func newTabGrowsFromTheCentre() {
        let full = CGRect(x: 0, y: 0, width: 402, height: 874)
        let r = NewTabZoom.plus.rect(in: full)
        #expect(abs(r.midX - 201) < 0.01 && abs(r.midY - 437) < 0.01)
        #expect(abs(r.width / full.width - 0.7) < 0.001)
        #expect(NewTabZoom.lastTabClosed.fromLoneSlot && !NewTabZoom.lastTabClosed.blurs)
    }

    /// Safari (browser-springs-verify.md): a one-frame jump toward the new
    /// target, then the destination's spring from rest.
    @Test func reversalJumpsTowardTheNewTargetThenStartsFromRest() {
        var s = TabZoomState()
        s.go(toOverview: true)
        run(&s, seconds: 0.13)
        let p = s.progress
        #expect(p > 0.3 && p < 0.9 && s.velocity > 0)
        s.go(toOverview: false, span: 244)
        #expect(abs(s.progress - (p - 20.0 / 244)) < 1e-9)
        #expect(s.velocity == 0 && s.target == 0 && s.spring == .reversalToPage)
        run(&s, seconds: 1.2)
        #expect(s.phase == .page && s.pageInteractive)

        s.go(toOverview: true)
        run(&s, seconds: 0.05)
        s.go(toOverview: false)
        run(&s, seconds: 0.1)
        let q = s.progress
        s.go(toOverview: true, span: 244)
        #expect(abs(s.progress - (q + 10.0 / 244)) < 1e-9 && s.spring == .reversalToOverview)
    }

    /// Opening a card replays Safari's zoom in: its first 60 Hz frame moves
    /// 7–11 pt of the 225 pt card-to-page travel, as Safari's.
    @Test func openReplaysSafarisZoomIn() {
        var s = TabZoomState(overview: true)
        s.go(toOverview: false)
        #expect(s.curve == .zoomIn)
        s.step(1.0 / 60)
        let firstFrame = (1 - s.progress) * 225
        #expect(firstFrame >= 6 && firstFrame <= 11, "\(firstFrame) pt")
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
