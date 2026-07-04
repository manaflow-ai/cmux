import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarRowSwipeGestureModelTests {
    @Test func verticalDominantGestureAfterZeroDeltaBeganIsNotClaimed() {
        var model = SidebarRowSwipeGestureModel()

        let began = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let changed = model.handle(.init(phase: .changed, scrollingDeltaX: 8, scrollingDeltaY: 12))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))

        #expect(began.claimed == false)
        #expect(began.offset == 0)
        #expect(changed.claimed == false)
        #expect(changed.offset == 0)
        #expect(changed.commit == nil)
        #expect(release.claimed == false)
    }

    @Test func horizontalDominantGestureAfterZeroDeltaBeganTracksAccumulatedDeltaX() {
        var model = SidebarRowSwipeGestureModel()

        let began = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let firstChanged = model.handle(.init(phase: .changed, scrollingDeltaX: 18, scrollingDeltaY: 4))
        let changed = model.handle(.init(phase: .changed, scrollingDeltaX: 22, scrollingDeltaY: 3))

        #expect(began.claimed == false)
        #expect(firstChanged.claimed)
        #expect(firstChanged.offset == 18)
        #expect(changed.claimed)
        #expect(changed.offset == 40)
    }

    @Test func nonzeroDeltaBeganStillClaimsHorizontalGesture() {
        var model = SidebarRowSwipeGestureModel()

        let began = model.handle(.init(phase: .began, scrollingDeltaX: 18, scrollingDeltaY: 4))

        #expect(began.claimed)
        #expect(began.offset == 18)
        #expect(began.commit == nil)
    }

    @Test func directionLockPreventsSwitchingSidesWithinOneGesture() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        _ = model.handle(.init(phase: .changed, scrollingDeltaX: 36, scrollingDeltaY: 2))
        let reversed = model.handle(.init(phase: .changed, scrollingDeltaX: -90, scrollingDeltaY: 1))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))

        #expect(reversed.claimed)
        #expect(reversed.offset == 0)
        #expect(release.claimed)
        #expect(release.commit == nil)
    }

    @Test func releaseBelowThresholdSnapsBackWithoutCommit() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        _ = model.handle(.init(phase: .changed, scrollingDeltaX: 28, scrollingDeltaY: 2))
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

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        _ = model.handle(.init(phase: .changed, scrollingDeltaX: deltaX, scrollingDeltaY: 1))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))

        #expect(release.claimed)
        #expect(release.offset == 0)
        #expect(release.commit == expectedAction)
        #expect(release.shouldAnimateOffset)
    }

    @Test func momentumAfterEndIsIgnoredWithoutReopeningRow() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        _ = model.handle(.init(phase: .changed, scrollingDeltaX: 70, scrollingDeltaY: 2))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let momentum = model.handle(.init(phase: .momentum, scrollingDeltaX: 80, scrollingDeltaY: 0))

        #expect(release.commit == .leading)
        #expect(momentum.claimed)
        #expect(momentum.offset == 0)
        #expect(momentum.commit == nil)
        #expect(momentum.shouldAnimateOffset == false)
    }

    @Test func phaselessWheelEventsAfterSwipeAreForwardedAndResetMomentumSuppression() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        _ = model.handle(.init(phase: .changed, scrollingDeltaX: 70, scrollingDeltaY: 2))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let firstWheel = model.handle(.init(phase: .changed, scrollingDeltaX: 0, scrollingDeltaY: 18))
        let secondWheel = model.handle(.init(phase: .changed, scrollingDeltaX: 0, scrollingDeltaY: 24))
        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let freshSwipe = model.handle(.init(phase: .changed, scrollingDeltaX: 18, scrollingDeltaY: 1))

        #expect(release.claimed)
        #expect(release.commit == .leading)
        #expect(firstWheel.claimed == false)
        #expect(firstWheel.offset == 0)
        #expect(firstWheel.commit == nil)
        #expect(secondWheel.claimed == false)
        #expect(secondWheel.offset == 0)
        #expect(secondWheel.commit == nil)
        #expect(freshSwipe.claimed)
        #expect(freshSwipe.offset == 18)
    }

    @Test func momentumEventsAfterSwipeRemainSuppressed() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        _ = model.handle(.init(phase: .changed, scrollingDeltaX: 70, scrollingDeltaY: 2))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let firstMomentum = model.handle(.init(phase: .momentum, scrollingDeltaX: 80, scrollingDeltaY: 0))
        let secondMomentum = model.handle(.init(phase: .momentum, scrollingDeltaX: 40, scrollingDeltaY: 0))

        #expect(release.claimed)
        #expect(release.commit == .leading)
        #expect(firstMomentum.claimed)
        #expect(firstMomentum.offset == 0)
        #expect(firstMomentum.commit == nil)
        #expect(firstMomentum.shouldAnimateOffset == false)
        #expect(secondMomentum.claimed)
        #expect(secondMomentum.offset == 0)
        #expect(secondMomentum.commit == nil)
        #expect(secondMomentum.shouldAnimateOffset == false)
    }

    @Test func rubberBandDampingCapsOffsetGrowthBeyondMaxReveal() {
        let configuration = SidebarRowSwipeGestureModel.Configuration()
        var model = SidebarRowSwipeGestureModel(configuration: configuration)

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let result = model.handle(.init(phase: .changed, scrollingDeltaX: 260, scrollingDeltaY: 4))
        let maximumRubberBandedOffset = configuration.maxRevealDistance +
            configuration.maxRevealDistance * configuration.rubberBandExtraLimitFraction

        #expect(result.claimed)
        #expect(result.offset > configuration.maxRevealDistance)
        #expect(result.offset < 260)
        #expect(result.offset == maximumRubberBandedOffset)
    }

    @Test func endingWhileUndecidedResetsToIdleWithoutClaiming() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let undecidedRelease = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))
        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let nextSwipe = model.handle(.init(phase: .changed, scrollingDeltaX: 18, scrollingDeltaY: 2))

        #expect(undecidedRelease.claimed == false)
        #expect(undecidedRelease.offset == 0)
        #expect(undecidedRelease.commit == nil)
        #expect(nextSwipe.claimed)
        #expect(nextSwipe.offset == 18)
    }

    @Test func commitZoneEngagesAtThreshold() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let threshold = model.handle(.init(phase: .changed, scrollingDeltaX: 64, scrollingDeltaY: 1))

        #expect(threshold.claimed)
        #expect(threshold.offset == 64)
        #expect(threshold.isInCommitZone)
        #expect(threshold.enteredCommitZone)
    }

    @Test func commitZoneDoesNotFlickerBetweenDisengageAndCommitThresholds() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        _ = model.handle(.init(phase: .changed, scrollingDeltaX: 64, scrollingDeltaY: 1))
        let insideHysteresis = model.handle(.init(phase: .changed, scrollingDeltaX: -2, scrollingDeltaY: 0))
        let atDisengageThreshold = model.handle(.init(phase: .changed, scrollingDeltaX: -2, scrollingDeltaY: 0))
        let belowDisengageThreshold = model.handle(.init(phase: .changed, scrollingDeltaX: -0.5, scrollingDeltaY: 0))

        #expect(insideHysteresis.offset == 62)
        #expect(insideHysteresis.isInCommitZone)
        #expect(insideHysteresis.enteredCommitZone == false)
        #expect(atDisengageThreshold.offset == 60)
        #expect(atDisengageThreshold.isInCommitZone)
        #expect(atDisengageThreshold.enteredCommitZone == false)
        #expect(belowDisengageThreshold.offset == 59.5)
        #expect(belowDisengageThreshold.isInCommitZone == false)
        #expect(belowDisengageThreshold.enteredCommitZone == false)
    }

    @Test func enteredCommitZoneFiresOncePerEntry() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let firstEntry = model.handle(.init(phase: .changed, scrollingDeltaX: 64, scrollingDeltaY: 1))
        let stillInZone = model.handle(.init(phase: .changed, scrollingDeltaX: 6, scrollingDeltaY: 0))
        let exitZone = model.handle(.init(phase: .changed, scrollingDeltaX: -11, scrollingDeltaY: 0))
        let secondEntry = model.handle(.init(phase: .changed, scrollingDeltaX: 5, scrollingDeltaY: 0))

        #expect(firstEntry.isInCommitZone)
        #expect(firstEntry.enteredCommitZone)
        #expect(stillInZone.isInCommitZone)
        #expect(stillInZone.enteredCommitZone == false)
        #expect(exitZone.offset == 59)
        #expect(exitZone.isInCommitZone == false)
        #expect(exitZone.enteredCommitZone == false)
        #expect(secondEntry.offset == 64)
        #expect(secondEntry.isInCommitZone)
        #expect(secondEntry.enteredCommitZone)
    }

    @Test func commitZoneEntryResetsAcrossGestures() {
        var model = SidebarRowSwipeGestureModel()

        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let firstEntry = model.handle(.init(phase: .changed, scrollingDeltaX: 64, scrollingDeltaY: 1))
        let release = model.handle(.init(phase: .ended, scrollingDeltaX: 0, scrollingDeltaY: 0))
        _ = model.handle(.init(phase: .began, scrollingDeltaX: 0, scrollingDeltaY: 0))
        let secondEntry = model.handle(.init(phase: .changed, scrollingDeltaX: 64, scrollingDeltaY: 1))

        #expect(firstEntry.enteredCommitZone)
        #expect(release.isInCommitZone == false)
        #expect(release.enteredCommitZone == false)
        #expect(secondEntry.enteredCommitZone)
    }

    @Test func narrowSidebarDisablesLeadingActionOnly() {
        var narrowLeadingModel = SidebarRowSwipeGestureModel()
        var narrowTrailingModel = SidebarRowSwipeGestureModel()
        var wideLeadingModel = SidebarRowSwipeGestureModel()

        let narrowLeading = narrowLeadingModel.handle(.init(
            phase: .began,
            scrollingDeltaX: 20,
            scrollingDeltaY: 0,
            containerWidth: 120
        ))
        let narrowTrailing = narrowTrailingModel.handle(.init(
            phase: .began,
            scrollingDeltaX: -20,
            scrollingDeltaY: 0,
            containerWidth: 120
        ))
        let wideLeading = wideLeadingModel.handle(.init(
            phase: .began,
            scrollingDeltaX: 20,
            scrollingDeltaY: 0,
            containerWidth: 200
        ))

        #expect(narrowLeading.claimed == false)
        #expect(narrowLeading.offset == 0)
        #expect(narrowTrailing.claimed)
        #expect(narrowTrailing.offset == -20)
        #expect(wideLeading.claimed)
        #expect(wideLeading.offset == 20)
    }
}
