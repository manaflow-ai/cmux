import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyScrollbarSyncPlanTests: XCTestCase {
    func testPreservesStoredTopVisibleRowWhenNewOutputArrives() {
        let plan = ghosttyScrollViewportSyncPlan(
            scrollbar: GhosttyScrollbar(total: 105, offset: 10, len: 20),
            storedTopVisibleRow: 70,
            isExplicitViewportChange: false
        )

        XCTAssertEqual(plan.targetTopVisibleRow, 70)
        XCTAssertEqual(plan.targetRowFromBottom, 15)
        XCTAssertEqual(plan.storedTopVisibleRow, 70)
    }

    func testExplicitViewportChangeUsesIncomingScrollbarPosition() {
        let plan = ghosttyScrollViewportSyncPlan(
            scrollbar: GhosttyScrollbar(total: 100, offset: 15, len: 20),
            storedTopVisibleRow: 70,
            isExplicitViewportChange: true
        )

        XCTAssertEqual(plan.targetTopVisibleRow, 65)
        XCTAssertEqual(plan.targetRowFromBottom, 15)
        XCTAssertEqual(plan.storedTopVisibleRow, 65)
    }

    func testBottomPositionClearsStoredAnchor() {
        let plan = ghosttyScrollViewportSyncPlan(
            scrollbar: GhosttyScrollbar(total: 100, offset: 0, len: 20),
            storedTopVisibleRow: 70,
            isExplicitViewportChange: true
        )

        XCTAssertEqual(plan.targetTopVisibleRow, 80)
        XCTAssertEqual(plan.targetRowFromBottom, 0)
        XCTAssertNil(plan.storedTopVisibleRow)
    }

    func testInternalScrollCorrectionDoesNotMarkExplicitViewportChange() {
        XCTAssertFalse(
            ghosttyShouldMarkExplicitViewportChange(
                action: "scroll_to_row:15",
                source: .internalCorrection
            )
        )
        XCTAssertTrue(
            ghosttyShouldMarkExplicitViewportChange(
                action: "scroll_to_row:15",
                source: .userInteraction
            )
        )
    }

    func testScrollWheelStartsExplicitViewportChange() {
        XCTAssertTrue(ghosttyShouldBeginExplicitViewportChange(for: .scrollWheel))
    }

    func testExplicitViewportChangeIsConsumedByFirstScrollbarUpdate() {
        let first = ghosttyConsumeExplicitViewportChange(
            pendingExplicitViewportChange: true,
            baselineScrollbar: nil,
            incomingScrollbar: GhosttyScrollbar(total: 100, offset: 15, len: 20)
        )

        XCTAssertTrue(first.isExplicitViewportChange)
        XCTAssertFalse(first.remainingPendingExplicitViewportChange)

        let second = ghosttyConsumeExplicitViewportChange(
            pendingExplicitViewportChange: first.remainingPendingExplicitViewportChange,
            baselineScrollbar: nil,
            incomingScrollbar: GhosttyScrollbar(total: 105, offset: 15, len: 20)
        )

        XCTAssertFalse(second.isExplicitViewportChange)
    }

    func testPendingExplicitViewportChangeDoesNotLeakIntoOutputOnlyUpdate() {
        let deferred = ghosttyConsumeExplicitViewportChange(
            pendingExplicitViewportChange: true,
            baselineScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20),
            incomingScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20)
        )

        XCTAssertFalse(deferred.isExplicitViewportChange)
        XCTAssertTrue(deferred.remainingPendingExplicitViewportChange)

        let leaked = ghosttyConsumeExplicitViewportChange(
            pendingExplicitViewportChange: deferred.remainingPendingExplicitViewportChange,
            baselineScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20),
            incomingScrollbar: GhosttyScrollbar(total: 105, offset: 15, len: 20)
        )

        XCTAssertFalse(leaked.isExplicitViewportChange)
        XCTAssertFalse(leaked.remainingPendingExplicitViewportChange)
    }

    func testPendingExplicitViewportChangeConsumesWhenViewportActuallyMoves() {
        let moved = ghosttyConsumeExplicitViewportChange(
            pendingExplicitViewportChange: true,
            baselineScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20),
            incomingScrollbar: GhosttyScrollbar(total: 100, offset: 15, len: 20)
        )

        XCTAssertTrue(moved.isExplicitViewportChange)
        XCTAssertFalse(moved.remainingPendingExplicitViewportChange)
    }

    func testAutomaticFocusRestoreIsSuppressedWhileReviewingScrollback() {
        XCTAssertFalse(ghosttyShouldRestoreAutomaticTerminalFocus(storedTopVisibleRow: 70))
        XCTAssertTrue(ghosttyShouldRestoreAutomaticTerminalFocus(storedTopVisibleRow: nil))
    }

    func testAutomaticEnsureFocusReassertIsSuppressedWhileReviewingScrollback() {
        XCTAssertFalse(
            ghosttyShouldAutomaticallyReassertTerminalFocus(
                storedTopVisibleRow: 70,
                focusRequestSource: .automaticEnsureFocus
            )
        )
        XCTAssertTrue(
            ghosttyShouldAutomaticallyReassertTerminalFocus(
                storedTopVisibleRow: 70,
                focusRequestSource: .explicitUserAction
            )
        )
    }

    func testAutomaticFirstResponderAcquisitionIsSuppressedWhileReviewingScrollback() {
        XCTAssertFalse(
            ghosttyShouldApplyTerminalSurfaceFocusOnFirstResponderAcquisition(
                storedTopVisibleRow: 70,
                acquisitionSource: .automaticWindowActivation
            )
        )
        XCTAssertTrue(
            ghosttyShouldApplyTerminalSurfaceFocusOnFirstResponderAcquisition(
                storedTopVisibleRow: 70,
                acquisitionSource: .directSurfaceInteraction
            )
        )
    }

    func testAutomaticFirstResponderRestoreWhileReviewingScrollbackRestoresResponderWithoutSurfaceReassert() {
        let plan = ghosttyAutomaticTerminalFocusRestorePlan(
            storedTopVisibleRow: 70,
            focusRequestSource: .automaticFirstResponderRestore
        )

        XCTAssertTrue(plan.shouldRestoreFirstResponder)
        XCTAssertFalse(plan.shouldReassertTerminalSurfaceFocus)
    }

    func testPassiveScrollbarUpdateKeepsCurrentViewportAnchorWhenStoredAnchorWasLost() {
        XCTAssertEqual(
            ghosttyResolvedStoredTopVisibleRow(
                storedTopVisibleRow: nil,
                currentViewportTopVisibleRow: 55,
                currentViewportRowFromBottom: 5,
                isExplicitViewportChange: false,
                hasPendingAnchorCorrection: false
            ),
            55
        )
    }

    func testPassiveScrollbarUpdateKeepsCurrentViewportAnchorAtTopWhenStoredAnchorWasLost() {
        XCTAssertEqual(
            ghosttyResolvedStoredTopVisibleRow(
                storedTopVisibleRow: nil,
                currentViewportTopVisibleRow: 69,
                currentViewportRowFromBottom: 0,
                isExplicitViewportChange: false,
                hasPendingAnchorCorrection: false
            ),
            69
        )
    }

    func testRegressivePassiveScrollbarSnapshotIsIgnoredWhileReviewingScrollback() {
        XCTAssertTrue(
            ghosttyShouldIgnoreStalePassiveScrollbarUpdate(
                previousScrollbar: GhosttyScrollbar(total: 201, offset: 0, len: 102),
                incomingScrollbar: GhosttyScrollbar(total: 172, offset: 70, len: 102),
                resolvedStoredTopVisibleRow: 73,
                resultingStoredTopVisibleRow: nil,
                isExplicitViewportChange: false
            )
        )
    }

    func testPassiveScrollbarUpdateKeepsRecoveredAnchorAtViewportExtreme() {
        let plan = ghosttyScrollViewportSyncPlan(
            scrollbar: GhosttyScrollbar(total: 202, offset: 100, len: 102),
            storedTopVisibleRow: 100,
            isExplicitViewportChange: false
        )

        XCTAssertEqual(plan.storedTopVisibleRow, 100)
    }

    func testPassiveLayoutSyncRecoversCurrentViewportWhenStoredAnchorWasLost() {
        let plan = ghosttyPassiveScrollViewportSyncPlan(
            scrollbar: GhosttyScrollbar(total: 206, offset: 104, len: 102),
            storedTopVisibleRow: nil,
            currentViewportTopVisibleRow: 104,
            currentViewportRowFromBottom: 0,
            hasPendingAnchorCorrection: false
        )

        XCTAssertEqual(plan.targetTopVisibleRow, 104)
        XCTAssertEqual(plan.storedTopVisibleRow, 104)
    }

    func testZeroHeightScrollbarSnapshotDoesNotCreateAnchor() {
        let plan = ghosttyScrollViewportSyncPlan(
            scrollbar: GhosttyScrollbar(total: 206, offset: 104, len: 0),
            storedTopVisibleRow: 104,
            isExplicitViewportChange: false
        )

        XCTAssertEqual(plan.targetTopVisibleRow, 0)
        XCTAssertEqual(plan.targetRowFromBottom, 0)
        XCTAssertNil(plan.storedTopVisibleRow)
    }

    func testStalePassiveScrollbarCheckUsesLastAcceptedScrollbarWhenSurfaceWasOverwritten() {
        let baseline = ghosttyBaselineScrollbarForIncomingUpdate(
            lastAcceptedScrollbar: GhosttyScrollbar(total: 183, offset: 0, len: 102),
            currentSurfaceScrollbar: GhosttyScrollbar(total: 180, offset: 78, len: 102)
        )

        XCTAssertTrue(
            ghosttyShouldIgnoreStalePassiveScrollbarUpdate(
                previousScrollbar: baseline,
                incomingScrollbar: GhosttyScrollbar(total: 180, offset: 78, len: 102),
                resolvedStoredTopVisibleRow: 81,
                resultingStoredTopVisibleRow: nil,
                isExplicitViewportChange: false
            )
        )
    }

    func testExplicitFocusRestoreAfterKeyLossAllowsOneUserInitiatedRestoreWhileReviewingScrollback() {
        let restored = ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
            pendingExplicitFocusRestoreAfterKeyLoss: true,
            hasLostKeySinceExplicitFocusRestoreRequest: true,
            baseFocusRequestSource: .automaticFirstResponderRestore
        )

        XCTAssertEqual(restored.focusRequestSource, .explicitUserAction)
        XCTAssertFalse(restored.remainingPendingExplicitFocusRestoreAfterKeyLoss)
        XCTAssertTrue(
            ghosttyShouldAutomaticallyReassertTerminalFocus(
                storedTopVisibleRow: 93,
                focusRequestSource: restored.focusRequestSource
            )
        )

        let ensure = ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
            pendingExplicitFocusRestoreAfterKeyLoss: true,
            hasLostKeySinceExplicitFocusRestoreRequest: true,
            baseFocusRequestSource: .automaticEnsureFocus
        )

        XCTAssertEqual(ensure.focusRequestSource, .explicitUserAction)

        let later = ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
            pendingExplicitFocusRestoreAfterKeyLoss: false,
            hasLostKeySinceExplicitFocusRestoreRequest: false,
            baseFocusRequestSource: .automaticFirstResponderRestore
        )

        XCTAssertEqual(later.focusRequestSource, .automaticFirstResponderRestore)
    }

    func testExplicitFocusRestoreWaitsForActualKeyLossBeforeConsumption() {
        let early = ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
            pendingExplicitFocusRestoreAfterKeyLoss: true,
            hasLostKeySinceExplicitFocusRestoreRequest: false,
            baseFocusRequestSource: .automaticFirstResponderRestore
        )

        XCTAssertEqual(early.focusRequestSource, .automaticFirstResponderRestore)
        XCTAssertTrue(early.remainingPendingExplicitFocusRestoreAfterKeyLoss)

        let afterKeyLoss = ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
            pendingExplicitFocusRestoreAfterKeyLoss: early.remainingPendingExplicitFocusRestoreAfterKeyLoss,
            hasLostKeySinceExplicitFocusRestoreRequest: true,
            baseFocusRequestSource: .automaticFirstResponderRestore
        )

        XCTAssertEqual(afterKeyLoss.focusRequestSource, .explicitUserAction)
        XCTAssertFalse(afterKeyLoss.remainingPendingExplicitFocusRestoreAfterKeyLoss)
    }

    func testRegressiveScrollbarSequenceFromNotificationDialogDoesNotClearRecoveredAnchor() {
        let recoveredAnchor = 97
        let recoveredPlan = ghosttyScrollViewportSyncPlan(
            scrollbar: GhosttyScrollbar(total: 229, offset: 0, len: 102),
            storedTopVisibleRow: recoveredAnchor,
            isExplicitViewportChange: false
        )

        XCTAssertEqual(recoveredPlan.storedTopVisibleRow, recoveredAnchor)
        XCTAssertTrue(
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
            )
        )
    }

    func testFailedScrollCorrectionDispatchKeepsRetryStateClear() {
        let failed = ghosttyScrollCorrectionDispatchState(
            previousLastSentRow: 4,
            previousPendingAnchorCorrectionRow: nil,
            targetRowFromBottom: 15,
            dispatchSucceeded: false
        )

        XCTAssertEqual(failed.lastSentRow, 4)
        XCTAssertNil(failed.pendingAnchorCorrectionRow)

        let succeeded = ghosttyScrollCorrectionDispatchState(
            previousLastSentRow: 4,
            previousPendingAnchorCorrectionRow: nil,
            targetRowFromBottom: 15,
            dispatchSucceeded: true
        )

        XCTAssertEqual(succeeded.lastSentRow, 15)
        XCTAssertEqual(succeeded.pendingAnchorCorrectionRow, 15)
    }
}
