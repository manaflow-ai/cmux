import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func testPreservesStoredTopVisibleRowWhenNewOutputArrives() {
    let plan = ghosttyScrollViewportSyncPlan(
        scrollbar: GhosttyScrollbar(total: 105, offset: 10, len: 20),
        storedTopVisibleRow: 70,
        isExplicitViewportChange: false
    )

    expect(plan.targetTopVisibleRow == 70, "expected stored top row to stay anchored")
    expect(plan.targetRowFromBottom == 15, "expected row-from-bottom to stay aligned with stored top row")
    expect(plan.storedTopVisibleRow == 70, "expected stored top row to persist while off bottom")
}

func testInternalScrollCorrectionDoesNotCountAsExplicitViewportChange() {
    expect(
        ghosttyShouldMarkExplicitViewportChange(
            action: "scroll_to_row:15",
            source: .internalCorrection
        ) == false,
        "internal scroll correction should not mark an explicit viewport change"
    )

    expect(
        ghosttyShouldMarkExplicitViewportChange(
            action: "scroll_to_row:15",
            source: .userInteraction
        ),
        "user scroll_to_row should still count as an explicit viewport change"
    )
}

func testScrollWheelStartsExplicitViewportChange() {
    expect(
        ghosttyShouldBeginExplicitViewportChange(for: .scrollWheel),
        "scroll wheel input should start an explicit viewport change window"
    )
}

func testExplicitViewportChangeIsConsumedByFirstScrollbarUpdate() {
    let first = ghosttyConsumeExplicitViewportChange(
        pendingExplicitViewportChange: true,
        baselineScrollbar: nil,
        incomingScrollbar: GhosttyScrollbar(total: 100, offset: 15, len: 20)
    )

    expect(
        first.isExplicitViewportChange,
        "the first scrollbar update after a user scroll should be explicit"
    )
    expect(
        first.remainingPendingExplicitViewportChange == false,
        "the explicit viewport change token should be consumed by that update"
    )

    let second = ghosttyConsumeExplicitViewportChange(
        pendingExplicitViewportChange: first.remainingPendingExplicitViewportChange,
        baselineScrollbar: nil,
        incomingScrollbar: GhosttyScrollbar(total: 105, offset: 15, len: 20)
    )

    expect(
        second.isExplicitViewportChange == false,
        "later output updates should not still count as the original explicit scroll"
    )
}

func testPendingExplicitViewportChangeDoesNotLeakIntoOutputOnlyUpdate() {
    let deferred = ghosttyConsumeExplicitViewportChange(
        pendingExplicitViewportChange: true,
        baselineScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20),
        incomingScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20)
    )

    expect(
        deferred.isExplicitViewportChange == false,
        "an unchanged scrollbar snapshot should not be treated as an explicit viewport change yet"
    )
    expect(
        deferred.remainingPendingExplicitViewportChange,
        "the explicit viewport change token should stay armed until something actually moves"
    )

    let leaked = ghosttyConsumeExplicitViewportChange(
        pendingExplicitViewportChange: deferred.remainingPendingExplicitViewportChange,
        baselineScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20),
        incomingScrollbar: GhosttyScrollbar(total: 105, offset: 15, len: 20)
    )

    expect(
        leaked.isExplicitViewportChange == false,
        "output-only growth at the same anchored top row should not consume the explicit viewport change token as user scroll"
    )
    expect(
        leaked.remainingPendingExplicitViewportChange == false,
        "once a passive output update arrives without a viewport move, the stale explicit token should be cleared"
    )
}

func testPendingExplicitViewportChangeConsumesWhenViewportActuallyMoves() {
    let moved = ghosttyConsumeExplicitViewportChange(
        pendingExplicitViewportChange: true,
        baselineScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20),
        incomingScrollbar: GhosttyScrollbar(total: 100, offset: 15, len: 20)
    )

    expect(
        moved.isExplicitViewportChange,
        "a pending explicit viewport change should be consumed once the viewport top row actually changes"
    )
    expect(
        moved.remainingPendingExplicitViewportChange == false,
        "the explicit viewport change token should clear after that viewport move"
    )
}

func testAutomaticFocusRestoreIsSuppressedWhileReviewingScrollback() {
    expect(
        ghosttyShouldRestoreAutomaticTerminalFocus(storedTopVisibleRow: 70) == false,
        "automatic focus restore should stay off while the user is reviewing older output"
    )
    expect(
        ghosttyShouldRestoreAutomaticTerminalFocus(storedTopVisibleRow: nil),
        "automatic focus restore should still work at the bottom"
    )
}

func testAutomaticEnsureFocusIsAlsoSuppressedWhileReviewingScrollback() {
    expect(
        ghosttyShouldAutomaticallyReassertTerminalFocus(
            storedTopVisibleRow: 70,
            focusRequestSource: .automaticEnsureFocus
        ) == false,
        "automatic ensureFocus should not re-focus the terminal while reviewing scrollback"
    )
    expect(
        ghosttyShouldAutomaticallyReassertTerminalFocus(
            storedTopVisibleRow: 70,
            focusRequestSource: .explicitUserAction
        ),
        "explicit user focus should still be allowed while reviewing scrollback"
    )
}

func testAutomaticFirstResponderAcquisitionIsSuppressedWhileReviewingScrollback() {
    expect(
        ghosttyShouldApplyTerminalSurfaceFocusOnFirstResponderAcquisition(
            storedTopVisibleRow: 70,
            acquisitionSource: .automaticWindowActivation
        ) == false,
        "automatic first-responder restoration should not focus the terminal while reviewing scrollback"
    )
    expect(
        ghosttyShouldApplyTerminalSurfaceFocusOnFirstResponderAcquisition(
            storedTopVisibleRow: 70,
            acquisitionSource: .directSurfaceInteraction
        ),
        "direct terminal interaction should still focus the terminal while reviewing scrollback"
    )
}

func testAutomaticFirstResponderRestoreWhileReviewingScrollbackRestoresResponderWithoutSurfaceReassert() {
    let plan = ghosttyAutomaticTerminalFocusRestorePlan(
        storedTopVisibleRow: 70,
        focusRequestSource: .automaticFirstResponderRestore
    )

    expect(
        plan.shouldRestoreFirstResponder,
        "automatic post-dialog focus recovery should still restore AppKit first responder while reviewing scrollback"
    )
    expect(
        plan.shouldReassertTerminalSurfaceFocus == false,
        "automatic post-dialog focus recovery should not reassert Ghostty surface focus while reviewing scrollback"
    )
}

func testPassiveScrollbarUpdateKeepsCurrentViewportAnchorWhenStoredAnchorWasLost() {
    let resolved = ghosttyResolvedStoredTopVisibleRow(
        storedTopVisibleRow: nil,
        currentViewportTopVisibleRow: 55,
        currentViewportRowFromBottom: 5,
        isExplicitViewportChange: false,
        hasPendingAnchorCorrection: false
    )

    expect(
        resolved == 55,
        "passive updates should preserve the current off-bottom viewport when the stored anchor was lost"
    )
}

func testPassiveScrollbarUpdateKeepsCurrentViewportAnchorAtTopWhenStoredAnchorWasLost() {
    let resolved = ghosttyResolvedStoredTopVisibleRow(
        storedTopVisibleRow: nil,
        currentViewportTopVisibleRow: 69,
        currentViewportRowFromBottom: 0,
        isExplicitViewportChange: false,
        hasPendingAnchorCorrection: false
    )

    expect(
        resolved == 69,
        "passive updates should preserve the current viewport even when it is at the top of scrollback"
    )
}

func testRegressivePassiveScrollbarSnapshotIsIgnoredWhileReviewingScrollback() {
    expect(
        ghosttyShouldIgnoreStalePassiveScrollbarUpdate(
            previousScrollbar: GhosttyScrollbar(total: 201, offset: 0, len: 102),
            incomingScrollbar: GhosttyScrollbar(total: 172, offset: 70, len: 102),
            resolvedStoredTopVisibleRow: 73,
            resultingStoredTopVisibleRow: nil,
            isExplicitViewportChange: false
        ),
        "regressive passive scrollbar snapshots should be ignored when they would clear an already-resolved scrollback anchor"
    )
}

func testPassiveScrollbarUpdateKeepsRecoveredAnchorAtViewportExtreme() {
    let plan = ghosttyScrollViewportSyncPlan(
        scrollbar: GhosttyScrollbar(total: 202, offset: 100, len: 102),
        storedTopVisibleRow: 100,
        isExplicitViewportChange: false
    )

    expect(
        plan.storedTopVisibleRow == 100,
        "passive scrollbar updates should preserve a recovered review anchor even when it clamps to the viewport extreme"
    )
}

func testPassiveLayoutSyncRecoversCurrentViewportWhenStoredAnchorWasLost() {
    let plan = ghosttyPassiveScrollViewportSyncPlan(
        scrollbar: GhosttyScrollbar(total: 206, offset: 104, len: 102),
        storedTopVisibleRow: nil,
        currentViewportTopVisibleRow: 104,
        currentViewportRowFromBottom: 0,
        hasPendingAnchorCorrection: false
    )

    expect(
        plan.targetTopVisibleRow == 104,
        "layout-driven sync should recover the current reviewed viewport when the stored anchor is missing"
    )
    expect(
        plan.storedTopVisibleRow == 104,
        "layout-driven sync should keep the recovered scrollback anchor instead of snapping to the scrollbar snapshot"
    )
}

func testZeroHeightScrollbarSnapshotDoesNotCreateAnchor() {
    let plan = ghosttyScrollViewportSyncPlan(
        scrollbar: GhosttyScrollbar(total: 206, offset: 104, len: 0),
        storedTopVisibleRow: 104,
        isExplicitViewportChange: false
    )

    expect(
        plan.targetTopVisibleRow == 0 && plan.targetRowFromBottom == 0,
        "zero-height scrollbar snapshots should be treated as non-actionable"
    )
    expect(
        plan.storedTopVisibleRow == nil,
        "zero-height scrollbar snapshots should not create or preserve a scrollback anchor"
    )
}

func testStalePassiveScrollbarCheckUsesLastAcceptedScrollbarWhenSurfaceWasOverwritten() {
    let baseline = ghosttyBaselineScrollbarForIncomingUpdate(
        lastAcceptedScrollbar: GhosttyScrollbar(total: 183, offset: 0, len: 102),
        currentSurfaceScrollbar: GhosttyScrollbar(total: 180, offset: 78, len: 102)
    )

    expect(
        ghosttyShouldIgnoreStalePassiveScrollbarUpdate(
            previousScrollbar: baseline,
            incomingScrollbar: GhosttyScrollbar(total: 180, offset: 78, len: 102),
            resolvedStoredTopVisibleRow: 81,
            resultingStoredTopVisibleRow: nil,
            isExplicitViewportChange: false
        ),
        "stale passive scrollbar checks should compare against the last accepted scrollbar, not the already-overwritten surface scrollbar"
    )
}

func testExplicitFocusRestoreAfterKeyLossAllowsOneUserInitiatedRestoreWhileReviewingScrollback() {
    let restored = ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
        pendingExplicitFocusRestoreAfterKeyLoss: true,
        hasLostKeySinceExplicitFocusRestoreRequest: true,
        baseFocusRequestSource: .automaticFirstResponderRestore
    )

    expect(
        restored.focusRequestSource == .explicitUserAction,
        "the first restore after a blue-ring click should be treated as explicit user focus"
    )
    expect(
        restored.remainingPendingExplicitFocusRestoreAfterKeyLoss == false,
        "the explicit focus token should be consumed by that restore"
    )
    expect(
        ghosttyShouldAutomaticallyReassertTerminalFocus(
            storedTopVisibleRow: 93,
            focusRequestSource: restored.focusRequestSource
        ),
        "the explicit restore should still be allowed while reviewing scrollback"
    )

    let ensure = ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
        pendingExplicitFocusRestoreAfterKeyLoss: true,
        hasLostKeySinceExplicitFocusRestoreRequest: true,
        baseFocusRequestSource: .automaticEnsureFocus
    )

    expect(
        ensure.focusRequestSource == .explicitUserAction,
        "the same explicit token should override ensureFocus as well"
    )

    let later = ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
        pendingExplicitFocusRestoreAfterKeyLoss: false,
        hasLostKeySinceExplicitFocusRestoreRequest: false,
        baseFocusRequestSource: .automaticFirstResponderRestore
    )

    expect(
        later.focusRequestSource == .automaticFirstResponderRestore,
        "later restores should go back to automatic behavior"
    )
}

func testExplicitFocusRestoreWaitsForActualKeyLossBeforeConsumption() {
    let early = ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
        pendingExplicitFocusRestoreAfterKeyLoss: true,
        hasLostKeySinceExplicitFocusRestoreRequest: false,
        baseFocusRequestSource: .automaticFirstResponderRestore
    )

    expect(
        early.focusRequestSource == .automaticFirstResponderRestore,
        "pre-dialog focus churn should not consume the explicit restore token before key loss"
    )
    expect(
        early.remainingPendingExplicitFocusRestoreAfterKeyLoss,
        "the explicit restore token should remain armed until the window actually loses key"
    )

    let afterKeyLoss = ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
        pendingExplicitFocusRestoreAfterKeyLoss: early.remainingPendingExplicitFocusRestoreAfterKeyLoss,
        hasLostKeySinceExplicitFocusRestoreRequest: true,
        baseFocusRequestSource: .automaticFirstResponderRestore
    )

    expect(
        afterKeyLoss.focusRequestSource == .explicitUserAction,
        "the first restore after key loss should consume the explicit token"
    )
    expect(
        afterKeyLoss.remainingPendingExplicitFocusRestoreAfterKeyLoss == false,
        "the explicit restore token should be cleared once that post-key-loss restore runs"
    )
}

func testRegressiveScrollbarSequenceFromNotificationDialogDoesNotClearRecoveredAnchor() {
    let recoveredAnchor = 97
    let recoveredPlan = ghosttyScrollViewportSyncPlan(
        scrollbar: GhosttyScrollbar(total: 229, offset: 0, len: 102),
        storedTopVisibleRow: recoveredAnchor,
        isExplicitViewportChange: false
    )

    expect(recoveredPlan.storedTopVisibleRow == recoveredAnchor, "the newer scrollbar snapshot should recover the scrollback anchor")

    expect(
        ghosttyShouldIgnoreStalePassiveScrollbarUpdate(
            previousScrollbar: GhosttyScrollbar(total: 229, offset: 0, len: 102),
            incomingScrollbar: GhosttyScrollbar(total: 199, offset: 97, len: 102),
            resolvedStoredTopVisibleRow: recoveredAnchor,
            resultingStoredTopVisibleRow: ghosttyScrollViewportSyncPlan(
                scrollbar: GhosttyScrollbar(total: 199, offset: 97, len: 102),
                storedTopVisibleRow: recoveredAnchor,
                isExplicitViewportChange: false
            ).storedTopVisibleRow,
            isExplicitViewportChange: false
        ),
        "the notification-dialog regression pair should be ignored before it can clear the recovered anchor"
    )
}

func testFailedScrollCorrectionDispatchDoesNotBlockRetry() {
    let failed = ghosttyScrollCorrectionDispatchState(
        previousLastSentRow: 4,
        previousPendingAnchorCorrectionRow: nil,
        targetRowFromBottom: 15,
        dispatchSucceeded: false
    )

    expect(failed.lastSentRow == 4, "failed correction should keep the previous last-sent row")
    expect(
        failed.pendingAnchorCorrectionRow == nil,
        "failed correction should not mark the target row as pending"
    )

    let succeeded = ghosttyScrollCorrectionDispatchState(
        previousLastSentRow: 4,
        previousPendingAnchorCorrectionRow: nil,
        targetRowFromBottom: 15,
        dispatchSucceeded: true
    )

    expect(succeeded.lastSentRow == 15, "successful correction should update the last-sent row")
    expect(
        succeeded.pendingAnchorCorrectionRow == 15,
        "successful correction should mark the target row as pending"
    )
}

@main
struct GhosttyViewportSyncLogicTestRunner {
    static func main() {
        testPreservesStoredTopVisibleRowWhenNewOutputArrives()
        testInternalScrollCorrectionDoesNotCountAsExplicitViewportChange()
        testScrollWheelStartsExplicitViewportChange()
        testExplicitViewportChangeIsConsumedByFirstScrollbarUpdate()
        testPendingExplicitViewportChangeDoesNotLeakIntoOutputOnlyUpdate()
        testPendingExplicitViewportChangeConsumesWhenViewportActuallyMoves()
        testAutomaticFocusRestoreIsSuppressedWhileReviewingScrollback()
        testAutomaticEnsureFocusIsAlsoSuppressedWhileReviewingScrollback()
        testAutomaticFirstResponderAcquisitionIsSuppressedWhileReviewingScrollback()
        testAutomaticFirstResponderRestoreWhileReviewingScrollbackRestoresResponderWithoutSurfaceReassert()
        testPassiveScrollbarUpdateKeepsCurrentViewportAnchorWhenStoredAnchorWasLost()
        testPassiveScrollbarUpdateKeepsCurrentViewportAnchorAtTopWhenStoredAnchorWasLost()
        testRegressivePassiveScrollbarSnapshotIsIgnoredWhileReviewingScrollback()
        testPassiveScrollbarUpdateKeepsRecoveredAnchorAtViewportExtreme()
        testPassiveLayoutSyncRecoversCurrentViewportWhenStoredAnchorWasLost()
        testZeroHeightScrollbarSnapshotDoesNotCreateAnchor()
        testStalePassiveScrollbarCheckUsesLastAcceptedScrollbarWhenSurfaceWasOverwritten()
        testExplicitFocusRestoreAfterKeyLossAllowsOneUserInitiatedRestoreWhileReviewingScrollback()
        testExplicitFocusRestoreWaitsForActualKeyLossBeforeConsumption()
        testRegressiveScrollbarSequenceFromNotificationDialogDoesNotClearRecoveredAnchor()
        testFailedScrollCorrectionDispatchDoesNotBlockRetry()
        print("PASS: ghostty viewport sync logic")
    }
}
