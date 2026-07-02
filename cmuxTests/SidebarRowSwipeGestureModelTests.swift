import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarRowSwipeGestureModelTests {
    @Test func verticalDominantGestureAtBeganIsNotClaimed() {
        var model = SidebarRowSwipeGestureModel()

        let result = model.handle(.init(phase: .began, scrollingDeltaX: 8, scrollingDeltaY: 12))

        #expect(result.claimed == false)
        #expect(result.offset == 0)
        #expect(result.commit == nil)
    }

    @Test func horizontalDominantGestureIsClaimedAndTracksAccumulatedDeltaX() {
        var model = SidebarRowSwipeGestureModel()

        let began = model.handle(.init(phase: .began, scrollingDeltaX: 18, scrollingDeltaY: 4))
        let changed = model.handle(.init(phase: .changed, scrollingDeltaX: 22, scrollingDeltaY: 3))

        #expect(began.claimed)
        #expect(began.offset == 18)
        #expect(changed.claimed)
        #expect(changed.offset == 40)
    }

    @Test func directionLockPreventsSwitchingSidesWithinOneGesture() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 36, scrollingDeltaY: 2))
        let reversed = model.handle(.init(phase: .changed, scrollingDeltaX: -90, scrollingDeltaY: 1))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))

        #expect(reversed.claimed)
        #expect(reversed.offset == 0)
        #expect(release.claimed)
        #expect(release.commit == nil)
    }

    @Test func releaseBelowThresholdSnapsBackWithoutCommit() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 28, scrollingDeltaY: 2))
        _ = model.handle(.init(phase: .changed, scrollingDeltaX: 20, scrollingDeltaY: 0))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))

        #expect(release.claimed)
        #expect(release.offset == 0)
        #expect(release.commit == nil)
        #expect(release.shouldAnimateOffset)
    }

    @Test(arguments: [
        (CGFloat(70), SidebarRowSwipeGestureModel.Action.leading),
        (CGFloat(-70), SidebarRowSwipeGestureModel.Action.trailing),
    ])
    func releaseBeyondThresholdCommitsCorrectActionSide(
        deltaX: CGFloat,
        expectedAction: SidebarRowSwipeGestureModel.Action
    ) {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: deltaX, scrollingDeltaY: 1))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))

        #expect(release.claimed)
        #expect(release.offset == 0)
        #expect(release.commit == expectedAction)
        #expect(release.shouldAnimateOffset)
    }

    @Test func momentumAfterEndIsIgnoredWithoutReopeningRow() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 70, scrollingDeltaY: 2))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let momentum = model.handle(.init(phase: .momentum, scrollingDeltaX: 80, scrollingDeltaY: 0))

        #expect(release.commit == .leading)
        #expect(momentum.claimed)
        #expect(momentum.offset == 0)
        #expect(momentum.commit == nil)
        #expect(momentum.shouldAnimateOffset == false)
    }

    @Test func rubberBandDampingCapsOffsetGrowthBeyondMaxReveal() {
        let configuration = SidebarRowSwipeGestureModel.Configuration()
        var model = SidebarRowSwipeGestureModel(configuration: configuration)

        let result = model.handle(.init(phase: .began, scrollingDeltaX: 260, scrollingDeltaY: 4))
        let maximumRubberBandedOffset = configuration.maxRevealDistance +
            configuration.maxRevealDistance * configuration.rubberBandExtraLimitFraction

        #expect(result.claimed)
        #expect(result.offset > configuration.maxRevealDistance)
        #expect(result.offset < 260)
        #expect(result.offset == maximumRubberBandedOffset)
    }
}
