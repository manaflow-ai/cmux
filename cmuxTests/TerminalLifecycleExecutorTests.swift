import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TerminalLifecycleExecutorTests: XCTestCase {
    func testVisibleTerminalWithoutReadyAnchorPlansWaitForAnchor() {
        let current = makeCurrentTerminalRecord(
            state: .awaitingAnchor,
            residency: .detachedRetained,
            activeWindowMembership: false,
            desiredActive: true,
            responderEligible: false,
            accessibilityParticipation: false
        )
        let desired = makeDesiredTerminalRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .awaitingAnchor,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetResponderEligible: true,
            targetAccessibilityParticipation: true,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: false
        )

        let plan = TerminalLifecycleExecutor.makePlan(currentRecords: [current], desiredRecords: [desired])

        XCTAssertEqual(plan.counts.panelCount, 1)
        XCTAssertEqual(plan.counts.waitForAnchorCount, 1)
        XCTAssertEqual(plan.records.first?.action, .waitForAnchor)
    }

    func testAnchorReadyVisibleTerminalPlansBindVisible() {
        let current = makeCurrentTerminalRecord(
            state: .awaitingAnchor,
            residency: .detachedRetained,
            activeWindowMembership: false,
            desiredActive: true,
            responderEligible: false,
            accessibilityParticipation: false
        )
        let desired = makeDesiredTerminalRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .boundVisible,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetResponderEligible: true,
            targetAccessibilityParticipation: true,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true
        )

        let plan = TerminalLifecycleExecutor.makePlan(currentRecords: [current], desiredRecords: [desired])

        XCTAssertEqual(plan.counts.bindVisibleCount, 1)
        XCTAssertEqual(plan.records.first?.action, .bindVisible)
    }

    func testHiddenTerminalPlansDetachRetained() {
        let current = makeCurrentTerminalRecord(
            state: .boundHidden,
            residency: .visibleInActiveWindow,
            activeWindowMembership: true,
            desiredActive: false,
            responderEligible: false,
            accessibilityParticipation: true
        )
        let desired = makeDesiredTerminalRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .parked,
            targetResidency: .detachedRetained,
            targetVisible: false,
            targetActive: false,
            targetResponderEligible: false,
            targetAccessibilityParticipation: false,
            requiresCurrentGenerationAnchor: false,
            anchorReadyForVisibility: false
        )

        let plan = TerminalLifecycleExecutor.makePlan(currentRecords: [current], desiredRecords: [desired])

        XCTAssertEqual(plan.counts.moveToDetachedRetainedCount, 1)
        XCTAssertEqual(plan.records.first?.action, .moveToDetachedRetained)
    }

    func testSatisfiedVisibleTerminalPlansNoop() {
        let current = makeCurrentTerminalRecord(
            state: .boundVisible,
            residency: .visibleInActiveWindow,
            activeWindowMembership: true,
            desiredActive: true,
            responderEligible: true,
            accessibilityParticipation: true
        )
        let desired = makeDesiredTerminalRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .boundVisible,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetResponderEligible: true,
            targetAccessibilityParticipation: true,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true
        )
        let binding = makeBinding(
            panelId: current.panelId,
            anchorId: desired.targetAnchorId,
            windowNumber: 41,
            visibleInUI: true,
            hostedHidden: false,
            attachedToPortalHost: true,
            guardGeneration: 5
        )

        let plan = TerminalLifecycleExecutor.makePlan(
            currentRecords: [current],
            desiredRecords: [desired],
            currentBindings: [binding]
        )

        XCTAssertEqual(plan.counts.noopCount, 1)
        XCTAssertEqual(plan.bindingCounts.panelCount, 1)
        XCTAssertEqual(plan.records.first?.action, .noop)
        XCTAssertEqual(plan.records.first?.bindingSatisfied, true)
    }

    func testPlannerOnlyIncludesTerminalRecords() {
        let terminalCurrent = makeCurrentTerminalRecord(
            state: .boundVisible,
            residency: .visibleInActiveWindow,
            activeWindowMembership: true,
            desiredActive: true,
            responderEligible: true,
            accessibilityParticipation: true
        )
        let browserCurrent = PanelLifecycleRecordSnapshot(
            panelId: UUID(),
            workspaceId: UUID(),
            paneId: UUID(),
            tabId: UUID(),
            panelType: .browser,
            generation: 5,
            state: .boundHidden,
            residency: .parkedOffscreen,
            mountedWorkspace: true,
            selectedWorkspace: false,
            retiringWorkspace: false,
            selectedInPane: false,
            desiredVisible: false,
            desiredActive: false,
            activeWindowMembership: false,
            responderEligible: false,
            accessibilityParticipation: false,
            backendProfile: PanelLifecycleShadowMapper.backendProfile(for: .browser),
            anchor: nil
        )
        let terminalDesired = makeDesiredTerminalRecord(
            panelId: terminalCurrent.panelId,
            workspaceId: terminalCurrent.workspaceId,
            targetState: .boundVisible,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetResponderEligible: true,
            targetAccessibilityParticipation: true,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true
        )
        let browserDesired = PanelLifecycleDesiredRecordSnapshot(
            panelId: browserCurrent.panelId,
            workspaceId: browserCurrent.workspaceId,
            panelType: .browser,
            generation: 5,
            targetState: .boundHidden,
            targetResidency: .parkedOffscreen,
            targetVisible: false,
            targetActive: false,
            targetWindowNumber: nil,
            targetAnchorId: nil,
            targetResponderEligible: false,
            targetAccessibilityParticipation: false,
            requiresCurrentGenerationAnchor: false,
            anchorReadyForVisibility: false
        )

        let plan = TerminalLifecycleExecutor.makePlan(
            currentRecords: [terminalCurrent, browserCurrent],
            desiredRecords: [terminalDesired, browserDesired]
        )

        XCTAssertEqual(plan.counts.panelCount, 1)
        XCTAssertEqual(plan.records.map(\.panelId), [terminalCurrent.panelId])
    }

    func testDesiredOnlyTerminalStillPlansVisibleBindWork() {
        let desired = makeDesiredTerminalRecord(
            targetState: .boundVisible,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetResponderEligible: true,
            targetAccessibilityParticipation: true,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true
        )

        let plan = TerminalLifecycleExecutor.makePlan(currentRecords: [], desiredRecords: [desired])

        XCTAssertEqual(plan.counts.panelCount, 1)
        XCTAssertEqual(plan.counts.bindVisibleCount, 1)
        XCTAssertEqual(plan.records.first?.currentState, .closed)
        XCTAssertEqual(plan.records.first?.currentResidency, .destroyed)
        XCTAssertEqual(plan.records.first?.action, .bindVisible)
    }

    func testVisibleTerminalWithWrongWindowBindingStillPlansBindVisible() {
        let current = makeCurrentTerminalRecord(
            state: .boundVisible,
            residency: .visibleInActiveWindow,
            activeWindowMembership: true,
            desiredActive: true,
            responderEligible: true,
            accessibilityParticipation: true
        )
        let desired = makeDesiredTerminalRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .boundVisible,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetResponderEligible: true,
            targetAccessibilityParticipation: true,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true
        )
        let binding = makeBinding(
            panelId: current.panelId,
            anchorId: desired.targetAnchorId,
            windowNumber: 99,
            visibleInUI: true,
            hostedHidden: false,
            attachedToPortalHost: true,
            guardGeneration: 5
        )

        let plan = TerminalLifecycleExecutor.makePlan(
            currentRecords: [current],
            desiredRecords: [desired],
            currentBindings: [binding]
        )

        XCTAssertEqual(plan.counts.bindVisibleCount, 1)
        XCTAssertEqual(plan.records.first?.bindingSatisfied, false)
        XCTAssertEqual(plan.records.first?.action, .bindVisible)
    }

    func testHiddenDetachWithLingeringBindingPlansDetachWork() {
        let current = makeCurrentTerminalRecord(
            state: .boundHidden,
            residency: .parkedOffscreen,
            activeWindowMembership: false,
            desiredActive: false,
            responderEligible: false,
            accessibilityParticipation: false
        )
        let desired = makeDesiredTerminalRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .parked,
            targetResidency: .detachedRetained,
            targetVisible: false,
            targetActive: false,
            targetResponderEligible: false,
            targetAccessibilityParticipation: false,
            requiresCurrentGenerationAnchor: false,
            anchorReadyForVisibility: false
        )
        let binding = makeBinding(
            panelId: current.panelId,
            windowNumber: 41,
            visibleInUI: false,
            hostedHidden: true,
            attachedToPortalHost: true,
            guardGeneration: 5
        )

        let plan = TerminalLifecycleExecutor.makePlan(
            currentRecords: [current],
            desiredRecords: [desired],
            currentBindings: [binding]
        )

        XCTAssertEqual(plan.counts.moveToDetachedRetainedCount, 1)
        XCTAssertEqual(plan.records.first?.action, .moveToDetachedRetained)
    }

    func testRuntimeVisibleSatisfiedBindingPlansNoop() {
        let binding = makeBinding(
            panelId: UUID(),
            windowNumber: 41,
            visibleInUI: true,
            hostedHidden: false,
            attachedToPortalHost: true,
            guardGeneration: 5
        )

        let decision = TerminalLifecycleExecutor.runtimeDecision(
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetWindowNumber: 41,
            targetAnchorId: binding.anchorId,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true,
            expectedGeneration: 5,
            binding: binding
        )

        XCTAssertEqual(decision.action, .noop)
        XCTAssertTrue(decision.bindingSatisfied)
        XCTAssertFalse(decision.shouldSynchronizeVisibleGeometry)
    }

    func testRuntimeHiddenDetachedRetainedWithoutBindingPlansNoop() {
        let decision = TerminalLifecycleExecutor.runtimeDecision(
            targetResidency: .detachedRetained,
            targetVisible: false,
            targetWindowNumber: nil,
            targetAnchorId: nil,
            requiresCurrentGenerationAnchor: false,
            anchorReadyForVisibility: false,
            expectedGeneration: nil,
            binding: nil
        )

        XCTAssertEqual(decision.action, .noop)
        XCTAssertFalse(decision.bindingSatisfied)
        XCTAssertFalse(decision.shouldSynchronizeVisibleGeometry)
    }

    func testRuntimeHiddenDetachedRetainedWithBindingPlansDetachWork() {
        let binding = makeBinding(
            panelId: UUID(),
            windowNumber: 41,
            visibleInUI: false,
            hostedHidden: true,
            attachedToPortalHost: true,
            guardGeneration: 5
        )

        let decision = TerminalLifecycleExecutor.runtimeDecision(
            targetResidency: .detachedRetained,
            targetVisible: false,
            targetWindowNumber: nil,
            targetAnchorId: nil,
            requiresCurrentGenerationAnchor: false,
            anchorReadyForVisibility: false,
            expectedGeneration: nil,
            binding: binding
        )

        XCTAssertEqual(decision.action, .moveToDetachedRetained)
        XCTAssertFalse(decision.bindingSatisfied)
        XCTAssertFalse(decision.shouldSynchronizeVisibleGeometry)
    }

    func testRuntimeTargetUsesDesiredVisibleRecord() {
        let desired = makeDesiredTerminalRecord(
            targetState: .boundVisible,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetResponderEligible: true,
            targetAccessibilityParticipation: true,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true
        )
        let binding = makeBinding(
            panelId: desired.panelId,
            anchorId: desired.targetAnchorId,
            windowNumber: 41,
            visibleInUI: true,
            hostedHidden: false,
            attachedToPortalHost: true,
            guardGeneration: 5
        )

        let target = TerminalLifecycleExecutor.runtimeTarget(
            desiredRecord: desired,
            fallbackVisible: false,
            fallbackActive: false,
            expectedAnchorId: desired.targetAnchorId,
            binding: binding
        )

        XCTAssertEqual(target.targetResidency, .visibleInActiveWindow)
        XCTAssertTrue(target.targetVisible)
        XCTAssertTrue(target.targetActive)
        XCTAssertTrue(target.shouldMountLiveAnchor)
        XCTAssertEqual(target.decision.action, .noop)
        XCTAssertTrue(target.decision.bindingSatisfied)
        XCTAssertFalse(target.decision.shouldSynchronizeVisibleGeometry)
    }

    func testRuntimeTargetFallsBackToDetachedRetainedWhenHiddenWithoutDesiredRecord() {
        let target = TerminalLifecycleExecutor.runtimeTarget(
            desiredRecord: nil,
            fallbackVisible: false,
            fallbackActive: false,
            expectedAnchorId: nil,
            binding: nil
        )

        XCTAssertEqual(target.targetResidency, .detachedRetained)
        XCTAssertFalse(target.targetVisible)
        XCTAssertFalse(target.targetActive)
        XCTAssertFalse(target.shouldMountLiveAnchor)
        XCTAssertEqual(target.decision.action, .noop)
        XCTAssertFalse(target.decision.shouldSynchronizeVisibleGeometry)
    }

    func testRuntimeTargetKeepsParkedOffscreenBindingWhenAlreadySatisfied() {
        let desired = makeDesiredTerminalRecord(
            targetState: .boundHidden,
            targetResidency: .parkedOffscreen,
            targetVisible: false,
            targetActive: false,
            targetResponderEligible: false,
            targetAccessibilityParticipation: false,
            requiresCurrentGenerationAnchor: false,
            anchorReadyForVisibility: false
        )
        let binding = makeBinding(
            panelId: desired.panelId,
            windowNumber: 41,
            visibleInUI: false,
            hostedHidden: true,
            attachedToPortalHost: true,
            guardGeneration: 5
        )

        let target = TerminalLifecycleExecutor.runtimeTarget(
            desiredRecord: desired,
            fallbackVisible: false,
            fallbackActive: false,
            expectedAnchorId: nil,
            binding: binding
        )

        XCTAssertEqual(target.targetResidency, .parkedOffscreen)
        XCTAssertFalse(target.shouldMountLiveAnchor)
        XCTAssertEqual(target.decision.action, .noop)
        XCTAssertTrue(target.decision.bindingSatisfied)
    }

    func testRuntimeTargetPlansParkedOffscreenMoveWhenBindingMissing() {
        let desired = makeDesiredTerminalRecord(
            targetState: .boundHidden,
            targetResidency: .parkedOffscreen,
            targetVisible: false,
            targetActive: false,
            targetResponderEligible: false,
            targetAccessibilityParticipation: false,
            requiresCurrentGenerationAnchor: false,
            anchorReadyForVisibility: false
        )

        let target = TerminalLifecycleExecutor.runtimeTarget(
            desiredRecord: desired,
            fallbackVisible: false,
            fallbackActive: false,
            expectedAnchorId: nil,
            binding: nil
        )

        XCTAssertEqual(target.targetResidency, .parkedOffscreen)
        XCTAssertFalse(target.shouldMountLiveAnchor)
        XCTAssertEqual(target.decision.action, .moveToParkedOffscreen)
        XCTAssertFalse(target.decision.bindingSatisfied)
    }

    func testRuntimeVisibleWithoutReadyAnchorPlansWaitForAnchor() {
        let decision = TerminalLifecycleExecutor.runtimeDecision(
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetWindowNumber: nil,
            targetAnchorId: nil,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: false,
            expectedGeneration: 5,
            binding: nil
        )

        XCTAssertEqual(decision.action, .waitForAnchor)
        XCTAssertFalse(decision.bindingSatisfied)
        XCTAssertFalse(decision.shouldSynchronizeVisibleGeometry)
    }

    func testRuntimeVisibleWrongAnchorStillPlansBindVisible() {
        let expectedAnchorId = UUID()
        let binding = makeBinding(
            panelId: UUID(),
            anchorId: UUID(),
            windowNumber: 41,
            visibleInUI: true,
            hostedHidden: false,
            attachedToPortalHost: true,
            guardGeneration: 5
        )

        let decision = TerminalLifecycleExecutor.runtimeDecision(
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetWindowNumber: 41,
            targetAnchorId: expectedAnchorId,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true,
            expectedGeneration: 5,
            binding: binding
        )

        XCTAssertEqual(decision.action, .bindVisible)
        XCTAssertFalse(decision.bindingSatisfied)
        XCTAssertFalse(decision.shouldSynchronizeVisibleGeometry)
    }

    func testRuntimeVisibleSatisfiedBindingWithGeometryDriftRequestsSynchronize() {
        let binding = makeBinding(
            panelId: UUID(),
            windowNumber: 41,
            visibleInUI: true,
            hostedHidden: false,
            attachedToPortalHost: true,
            guardGeneration: 5
        )

        let decision = TerminalLifecycleExecutor.runtimeDecision(
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetWindowNumber: 41,
            targetAnchorId: binding.anchorId,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true,
            expectedGeneration: 5,
            binding: binding,
            currentGeometryRevision: 7,
            lastSynchronizedGeometryRevision: 6
        )

        XCTAssertEqual(decision.action, .noop)
        XCTAssertTrue(decision.bindingSatisfied)
        XCTAssertTrue(decision.shouldSynchronizeVisibleGeometry)
        XCTAssertTrue(decision.shouldAdvanceSynchronizedGeometryRevision)
    }

    func testRuntimeVisibleSatisfiedBindingWithSameGeometrySkipsSynchronize() {
        let binding = makeBinding(
            panelId: UUID(),
            windowNumber: 41,
            visibleInUI: true,
            hostedHidden: false,
            attachedToPortalHost: true,
            guardGeneration: 5
        )

        let decision = TerminalLifecycleExecutor.runtimeDecision(
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetWindowNumber: 41,
            targetAnchorId: binding.anchorId,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true,
            expectedGeneration: 5,
            binding: binding,
            currentGeometryRevision: 7,
            lastSynchronizedGeometryRevision: 7
        )

        XCTAssertEqual(decision.action, .noop)
        XCTAssertTrue(decision.bindingSatisfied)
        XCTAssertFalse(decision.shouldSynchronizeVisibleGeometry)
        XCTAssertFalse(decision.shouldAdvanceSynchronizedGeometryRevision)
    }

    func testRuntimeBindVisibleAdvancesSynchronizedGeometryRevision() {
        let decision = TerminalLifecycleExecutor.runtimeDecision(
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetWindowNumber: 41,
            targetAnchorId: UUID(),
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true,
            expectedGeneration: 5,
            binding: nil
        )

        XCTAssertEqual(decision.action, .bindVisible)
        XCTAssertFalse(decision.shouldSynchronizeVisibleGeometry)
        XCTAssertTrue(decision.shouldAdvanceSynchronizedGeometryRevision)
    }

    func testRuntimeApplicationPlanSynchronizesSatisfiedVisibleBindings() {
        let plan = TerminalLifecycleExecutor.runtimeApplicationPlan(
            target: TerminalLifecycleExecutorRuntimeTarget(
                targetResidency: .visibleInActiveWindow,
                targetVisible: true,
                targetActive: true,
                targetWindowNumber: 41,
                targetAnchorId: UUID(),
                requiresCurrentGenerationAnchor: true,
                anchorReadyForVisibility: true,
                decision: TerminalLifecycleExecutorRuntimeDecision(
                    action: .noop,
                    bindingSatisfied: true,
                    shouldSynchronizeVisibleGeometry: true
                )
            )
        )

        XCTAssertTrue(plan.shouldUpdateEntryVisibility)
        XCTAssertTrue(plan.shouldSynchronizeForAnchor)
        XCTAssertFalse(plan.shouldBindVisible)
        XCTAssertFalse(plan.shouldDetachHostedView)
        XCTAssertFalse(plan.shouldUnmountHostedView)
    }

    func testRuntimeApplicationPlanWaitForAnchorOnlyUpdatesEntryVisibility() {
        let plan = TerminalLifecycleExecutor.runtimeApplicationPlan(
            target: TerminalLifecycleExecutorRuntimeTarget(
                targetResidency: .visibleInActiveWindow,
                targetVisible: true,
                targetActive: true,
                targetWindowNumber: 41,
                targetAnchorId: UUID(),
                requiresCurrentGenerationAnchor: true,
                anchorReadyForVisibility: false,
                decision: TerminalLifecycleExecutorRuntimeDecision(
                    action: .waitForAnchor,
                    bindingSatisfied: false,
                    shouldSynchronizeVisibleGeometry: false
                )
            )
        )

        XCTAssertTrue(plan.shouldUpdateEntryVisibility)
        XCTAssertFalse(plan.shouldSynchronizeForAnchor)
        XCTAssertFalse(plan.shouldBindVisible)
        XCTAssertFalse(plan.shouldDetachHostedView)
        XCTAssertFalse(plan.shouldUnmountHostedView)
    }

    func testRuntimeApplicationPlanUnmountsParkedOffscreenTargets() {
        let plan = TerminalLifecycleExecutor.runtimeApplicationPlan(
            target: TerminalLifecycleExecutorRuntimeTarget(
                targetResidency: .parkedOffscreen,
                targetVisible: false,
                targetActive: false,
                targetWindowNumber: nil,
                targetAnchorId: nil,
                requiresCurrentGenerationAnchor: false,
                anchorReadyForVisibility: false,
                decision: TerminalLifecycleExecutorRuntimeDecision(
                    action: .moveToParkedOffscreen,
                    bindingSatisfied: false,
                    shouldSynchronizeVisibleGeometry: false
                )
            )
        )

        XCTAssertTrue(plan.shouldUpdateEntryVisibility)
        XCTAssertFalse(plan.shouldSynchronizeForAnchor)
        XCTAssertFalse(plan.shouldBindVisible)
        XCTAssertFalse(plan.shouldDetachHostedView)
        XCTAssertTrue(plan.shouldUnmountHostedView)
    }

    func testHandoffReadyRequiresCurrentGenerationBoundVisibleSatisfiedBinding() {
        let current = makeCurrentTerminalRecord(
            state: .boundVisible,
            residency: .visibleInActiveWindow,
            activeWindowMembership: true,
            desiredActive: true,
            responderEligible: true,
            accessibilityParticipation: true
        )
        let desired = makeDesiredTerminalRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .boundVisible,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetResponderEligible: true,
            targetAccessibilityParticipation: true,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true
        )
        let binding = makeBinding(
            panelId: current.panelId,
            anchorId: desired.targetAnchorId,
            windowNumber: 41,
            visibleInUI: true,
            hostedHidden: false,
            attachedToPortalHost: true,
            guardGeneration: current.generation
        )

        let ready = TerminalLifecycleExecutor.isCurrentGenerationBoundVisibleReadyForWorkspaceHandoff(
            currentRecord: current,
            desiredRecord: desired,
            binding: binding
        )

        XCTAssertTrue(ready)
    }

    func testHandoffReadyRejectsStaleVisibleBinding() {
        let current = makeCurrentTerminalRecord(
            state: .boundVisible,
            residency: .visibleInActiveWindow,
            activeWindowMembership: true,
            desiredActive: true,
            responderEligible: true,
            accessibilityParticipation: true
        )
        let desired = makeDesiredTerminalRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .boundVisible,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetResponderEligible: true,
            targetAccessibilityParticipation: true,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true
        )
        let binding = makeBinding(
            panelId: current.panelId,
            anchorId: UUID(),
            windowNumber: 41,
            visibleInUI: true,
            hostedHidden: false,
            attachedToPortalHost: true,
            guardGeneration: current.generation
        )

        let ready = TerminalLifecycleExecutor.isCurrentGenerationBoundVisibleReadyForWorkspaceHandoff(
            currentRecord: current,
            desiredRecord: desired,
            binding: binding
        )

        XCTAssertFalse(ready)
    }

    func testHandoffReadyRejectsCurrentStateMismatch() {
        let current = makeCurrentTerminalRecord(
            state: .awaitingAnchor,
            residency: .detachedRetained,
            activeWindowMembership: false,
            desiredActive: true,
            responderEligible: false,
            accessibilityParticipation: false
        )
        let desired = makeDesiredTerminalRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .boundVisible,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetResponderEligible: true,
            targetAccessibilityParticipation: true,
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true
        )
        let binding = makeBinding(
            panelId: current.panelId,
            anchorId: desired.targetAnchorId,
            windowNumber: 41,
            visibleInUI: true,
            hostedHidden: false,
            attachedToPortalHost: true,
            guardGeneration: current.generation
        )

        let ready = TerminalLifecycleExecutor.isCurrentGenerationBoundVisibleReadyForWorkspaceHandoff(
            currentRecord: current,
            desiredRecord: desired,
            binding: binding
        )

        XCTAssertFalse(ready)
    }

    func testHostedStateApplicationPlanAppliesWhenBoundToCurrentHost() {
        let target = TerminalLifecycleExecutorRuntimeTarget(
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetWindowNumber: 41,
            targetAnchorId: UUID(),
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true,
            decision: TerminalLifecycleExecutorRuntimeDecision(
                action: .noop,
                bindingSatisfied: true,
                shouldSynchronizeVisibleGeometry: false
            )
        )

        let result = TerminalLifecycleExecutor.hostedStateApplicationPlan(
            target: target,
            hostedViewHasSuperview: true,
            isBoundToCurrentHost: true
        )

        XCTAssertTrue(result.shouldApplyImmediately)
        XCTAssertTrue(result.visibleInUI)
        XCTAssertTrue(result.active)
    }

    func testHostedStateApplicationPlanDefersForStaleVisibleHostBinding() {
        let target = TerminalLifecycleExecutorRuntimeTarget(
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetWindowNumber: 41,
            targetAnchorId: UUID(),
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true,
            decision: TerminalLifecycleExecutorRuntimeDecision(
                action: .bindVisible,
                bindingSatisfied: false,
                shouldSynchronizeVisibleGeometry: false
            )
        )

        let result = TerminalLifecycleExecutor.hostedStateApplicationPlan(
            target: target,
            hostedViewHasSuperview: true,
            isBoundToCurrentHost: false
        )

        XCTAssertFalse(result.shouldApplyImmediately)
        XCTAssertTrue(result.visibleInUI)
        XCTAssertTrue(result.active)
    }

    func testHostedStateApplicationPlanAppliesWhenHostedViewDetached() {
        let target = TerminalLifecycleExecutorRuntimeTarget(
            targetResidency: .detachedRetained,
            targetVisible: false,
            targetActive: false,
            targetWindowNumber: nil,
            targetAnchorId: nil,
            requiresCurrentGenerationAnchor: false,
            anchorReadyForVisibility: false,
            decision: TerminalLifecycleExecutorRuntimeDecision(
                action: .noop,
                bindingSatisfied: false,
                shouldSynchronizeVisibleGeometry: false
            )
        )

        let result = TerminalLifecycleExecutor.hostedStateApplicationPlan(
            target: target,
            hostedViewHasSuperview: false,
            isBoundToCurrentHost: false
        )

        XCTAssertTrue(result.shouldApplyImmediately)
        XCTAssertFalse(result.visibleInUI)
        XCTAssertFalse(result.active)
    }

    func testRecoveryDecisionRequestsVisibleReattachForMissingWindowBinding() {
        let target = TerminalLifecycleExecutorRuntimeTarget(
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetWindowNumber: 41,
            targetAnchorId: UUID(),
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true,
            decision: TerminalLifecycleExecutorRuntimeDecision(
                action: .bindVisible,
                bindingSatisfied: false,
                shouldSynchronizeVisibleGeometry: false
            )
        )

        let decision = TerminalLifecycleExecutor.recoveryDecision(
            target: target,
            hostedView: TerminalLifecycleExecutorHostedViewSnapshot(
                hasSuperview: true,
                inWindow: false,
                hidden: false,
                hasUsableGeometry: true,
                hasSurface: true
            )
        )

        XCTAssertTrue(decision.shouldRequestViewReattach)
        XCTAssertFalse(decision.shouldRequestBackgroundSurfaceStart)
        XCTAssertTrue(decision.shouldScheduleGeometryReconcile)
    }

    func testRecoveryDecisionRequestsBackgroundStartWhenSurfaceMissing() {
        let target = TerminalLifecycleExecutorRuntimeTarget(
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: true,
            targetWindowNumber: 41,
            targetAnchorId: UUID(),
            requiresCurrentGenerationAnchor: true,
            anchorReadyForVisibility: true,
            decision: TerminalLifecycleExecutorRuntimeDecision(
                action: .noop,
                bindingSatisfied: true,
                shouldSynchronizeVisibleGeometry: false
            )
        )

        let decision = TerminalLifecycleExecutor.recoveryDecision(
            target: target,
            hostedView: TerminalLifecycleExecutorHostedViewSnapshot(
                hasSuperview: true,
                inWindow: true,
                hidden: false,
                hasUsableGeometry: true,
                hasSurface: false
            )
        )

        XCTAssertFalse(decision.shouldRequestViewReattach)
        XCTAssertTrue(decision.shouldRequestBackgroundSurfaceStart)
        XCTAssertTrue(decision.shouldScheduleGeometryReconcile)
    }

    func testRecoveryDecisionSkipsHiddenTargets() {
        let target = TerminalLifecycleExecutorRuntimeTarget(
            targetResidency: .detachedRetained,
            targetVisible: false,
            targetActive: false,
            targetWindowNumber: nil,
            targetAnchorId: nil,
            requiresCurrentGenerationAnchor: false,
            anchorReadyForVisibility: false,
            decision: TerminalLifecycleExecutorRuntimeDecision(
                action: .noop,
                bindingSatisfied: false,
                shouldSynchronizeVisibleGeometry: false
            )
        )

        let decision = TerminalLifecycleExecutor.recoveryDecision(
            target: target,
            hostedView: TerminalLifecycleExecutorHostedViewSnapshot(
                hasSuperview: false,
                inWindow: false,
                hidden: true,
                hasUsableGeometry: false,
                hasSurface: false
            )
        )

        XCTAssertFalse(decision.shouldRequestViewReattach)
        XCTAssertFalse(decision.shouldRequestBackgroundSurfaceStart)
        XCTAssertFalse(decision.shouldScheduleGeometryReconcile)
    }

    func testVisibilityTransitionPreservesVisibleHostedViewDuringTransientLoss() {
        let decision = TerminalLifecycleExecutor.visibilityTransitionDecision(
            targetVisible: true,
            hostedHidden: false,
            shouldHide: true,
            revealReadyForDisplay: false,
            didScheduleTransientRecovery: true
        )

        XCTAssertTrue(decision.shouldPreserveVisibleOnTransientLoss)
        XCTAssertFalse(decision.shouldDeferReveal)
        XCTAssertFalse(decision.shouldRevealHostedView)
    }

    func testVisibilityTransitionDoesNotPreserveVisibleHostedViewWithoutScheduledRecovery() {
        let decision = TerminalLifecycleExecutor.visibilityTransitionDecision(
            targetVisible: true,
            hostedHidden: false,
            shouldHide: true,
            revealReadyForDisplay: false,
            didScheduleTransientRecovery: false
        )

        XCTAssertFalse(decision.shouldPreserveVisibleOnTransientLoss)
        XCTAssertFalse(decision.shouldDeferReveal)
        XCTAssertFalse(decision.shouldRevealHostedView)
    }

    func testVisibilityTransitionDefersRevealUntilFrameIsLargeEnough() {
        let decision = TerminalLifecycleExecutor.visibilityTransitionDecision(
            targetVisible: true,
            hostedHidden: true,
            shouldHide: false,
            revealReadyForDisplay: false,
            didScheduleTransientRecovery: false
        )

        XCTAssertFalse(decision.shouldPreserveVisibleOnTransientLoss)
        XCTAssertTrue(decision.shouldDeferReveal)
        XCTAssertFalse(decision.shouldRevealHostedView)
    }

    func testVisibilityTransitionRevealsHiddenHostedViewWhenReady() {
        let decision = TerminalLifecycleExecutor.visibilityTransitionDecision(
            targetVisible: true,
            hostedHidden: true,
            shouldHide: false,
            revealReadyForDisplay: true,
            didScheduleTransientRecovery: false
        )

        XCTAssertFalse(decision.shouldPreserveVisibleOnTransientLoss)
        XCTAssertFalse(decision.shouldDeferReveal)
        XCTAssertTrue(decision.shouldRevealHostedView)
    }

    func testTransientRecoveryReasonSkipsHiddenTargets() {
        let reason = TerminalLifecycleExecutor.transientRecoveryReason(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: true,
                targetVisible: false,
                missingAnchorOrWindow: true,
                anchorWindowMismatch: false,
                hostBoundsNotReady: false,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                shouldDeferReveal: false
            )
        )

        XCTAssertNil(reason)
    }

    func testTransientRecoveryReasonPrefersAnchorWindowMismatchBeforeGeometryReasons() {
        let reason = TerminalLifecycleExecutor.transientRecoveryReason(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: true,
                targetVisible: true,
                missingAnchorOrWindow: false,
                anchorWindowMismatch: true,
                hostBoundsNotReady: false,
                anchorHidden: true,
                hasFiniteFrame: false,
                outsideHostBounds: true,
                tinyFrame: true,
                shouldDeferReveal: true
            )
        )

        XCTAssertEqual(reason, .anchorWindowMismatch)
    }

    func testTransientRecoveryReasonUsesDeferRevealWhenNoEarlierTransientLossApplies() {
        let reason = TerminalLifecycleExecutor.transientRecoveryReason(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: true,
                targetVisible: true,
                missingAnchorOrWindow: false,
                anchorWindowMismatch: false,
                hostBoundsNotReady: false,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                shouldDeferReveal: true
            )
        )

        XCTAssertEqual(reason, .deferReveal)
    }

    func testTransientLossPlanRequestsRecoveryForVisibleMissingAnchor() {
        let plan = TerminalLifecycleExecutor.transientLossPlan(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: true,
                targetVisible: true,
                missingAnchorOrWindow: true,
                anchorWindowMismatch: false,
                hostBoundsNotReady: false,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                shouldDeferReveal: false
            ),
            hostedHidden: false
        )

        XCTAssertEqual(plan.transientRecoveryReason, .missingAnchorOrWindow)
        XCTAssertTrue(plan.shouldRequestTransientRecovery)
        XCTAssertEqual(plan.transientRetryDirective, .schedule(.missingAnchorOrWindow))
        let applicationPlan = plan.applicationPlan(didScheduleTransientRecovery: true)
        XCTAssertEqual(applicationPlan.transientRecoveryReason, .missingAnchorOrWindow)
        XCTAssertEqual(applicationPlan.transientRetryDirective, .schedule(.missingAnchorOrWindow))
        XCTAssertEqual(applicationPlan.hiddenStateAction, .preserveVisible)
        XCTAssertEqual(applicationPlan.followUpAction, .none)
    }

    func testTransientLossPlanFallsBackToHideWhenRecoveryDoesNotSchedule() {
        let plan = TerminalLifecycleExecutor.transientLossPlan(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: true,
                targetVisible: true,
                missingAnchorOrWindow: false,
                anchorWindowMismatch: false,
                hostBoundsNotReady: true,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                shouldDeferReveal: false
            ),
            hostedHidden: false
        )

        XCTAssertEqual(plan.transientRecoveryReason, .hostBoundsNotReady)
        XCTAssertTrue(plan.shouldRequestTransientRecovery)
        XCTAssertEqual(plan.transientRetryDirective, .schedule(.hostBoundsNotReady))
        let applicationPlan = plan.applicationPlan(didScheduleTransientRecovery: false)
        XCTAssertEqual(applicationPlan.transientRecoveryReason, .hostBoundsNotReady)
        XCTAssertEqual(applicationPlan.hiddenStateAction, .hideHostedView)
        XCTAssertEqual(applicationPlan.followUpAction, .retry(.hostBoundsNotReady))
    }

    func testTransientLossPlanUnmountsHiddenTargetsWithoutRecovery() {
        let plan = TerminalLifecycleExecutor.transientLossPlan(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: true,
                targetVisible: false,
                missingAnchorOrWindow: true,
                anchorWindowMismatch: false,
                hostBoundsNotReady: false,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                shouldDeferReveal: false
            ),
            hostedHidden: true
        )

        XCTAssertNil(plan.transientRecoveryReason)
        XCTAssertFalse(plan.shouldRequestTransientRecovery)
        XCTAssertEqual(plan.transientRetryDirective, .reset)
        XCTAssertEqual(
            plan.hiddenStateAction(didScheduleTransientRecovery: true),
            .unmountHostedView
        )
        XCTAssertEqual(
            plan.followUpAction,
            .none
        )
    }

    func testTransientLossPlanFollowUpRetriesWhenReasonPresent() {
        let plan = TerminalLifecycleExecutor.transientLossPlan(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: true,
                targetVisible: true,
                missingAnchorOrWindow: false,
                anchorWindowMismatch: true,
                hostBoundsNotReady: false,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                shouldDeferReveal: false
            ),
            hostedHidden: true
        )

        XCTAssertEqual(
            plan.followUpAction,
            .retry(.anchorWindowMismatch)
        )
    }

    func testTransientLossPlanFollowUpCanRequestDeferredFullSynchronize() {
        let plan = TerminalLifecycleExecutor.transientLossPlan(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: false,
                targetVisible: true,
                missingAnchorOrWindow: false,
                anchorWindowMismatch: false,
                hostBoundsNotReady: true,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                shouldDeferReveal: false
            ),
            hostedHidden: true
        )

        XCTAssertEqual(
            plan.followUpAction,
            .deferredFullSynchronize
        )
    }

    func testTransientLossApplicationPlanPreservesFollowUpStrategy() {
        let plan = TerminalLifecycleExecutor.transientLossPlan(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: true,
                targetVisible: true,
                missingAnchorOrWindow: false,
                anchorWindowMismatch: true,
                hostBoundsNotReady: false,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                shouldDeferReveal: false
            ),
            hostedHidden: true
        )

        let applicationPlan = plan.applicationPlan(didScheduleTransientRecovery: true)

        XCTAssertEqual(applicationPlan.transientRecoveryReason, .anchorWindowMismatch)
        XCTAssertEqual(applicationPlan.transientRetryDirective, .schedule(.anchorWindowMismatch))
        XCTAssertEqual(applicationPlan.hiddenStateAction, .hideHostedView)
        XCTAssertEqual(applicationPlan.followUpAction, .retry(.anchorWindowMismatch))
    }

    func testTransientLossApplicationPlanCarriesResetDirectiveForHiddenTargets() {
        let plan = TerminalLifecycleExecutor.transientLossPlan(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: true,
                targetVisible: false,
                missingAnchorOrWindow: true,
                anchorWindowMismatch: false,
                hostBoundsNotReady: false,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                shouldDeferReveal: false
            ),
            hostedHidden: true
        )

        let applicationPlan = plan.applicationPlan(didScheduleTransientRecovery: false)

        XCTAssertNil(applicationPlan.transientRecoveryReason)
        XCTAssertEqual(applicationPlan.transientRetryDirective, .reset)
        XCTAssertEqual(applicationPlan.hiddenStateAction, .unmountHostedView)
        XCTAssertEqual(applicationPlan.followUpAction, .none)
    }

    func testFrameLossPlanDerivesHideAndTransientReasonFromFrameLoss() {
        let plan = TerminalLifecycleExecutor.frameLossPlan(
            context: TerminalLifecycleExecutorFrameVisibilityContext(
                transientRecoveryEnabled: true,
                targetVisible: true,
                hostedHidden: false,
                anchorHidden: true,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                revealReadyForDisplay: false
            )
        )

        XCTAssertTrue(plan.shouldHide)
        XCTAssertFalse(plan.shouldDeferReveal)
        XCTAssertEqual(plan.transientRecoveryReason, .anchorHidden)
        XCTAssertTrue(plan.shouldRequestTransientRecovery)
        XCTAssertEqual(plan.transientRetryDirective, .schedule(.anchorHidden))
        XCTAssertEqual(
            plan.hiddenStateAction(didScheduleTransientRecovery: true),
            .preserveVisible
        )
    }

    func testFrameLossPlanUsesDeferRevealForHiddenHostedViewUntilFrameIsReady() {
        let plan = TerminalLifecycleExecutor.frameLossPlan(
            context: TerminalLifecycleExecutorFrameVisibilityContext(
                transientRecoveryEnabled: true,
                targetVisible: true,
                hostedHidden: true,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                revealReadyForDisplay: false
            )
        )

        XCTAssertFalse(plan.shouldHide)
        XCTAssertTrue(plan.shouldDeferReveal)
        XCTAssertEqual(plan.transientRecoveryReason, .deferReveal)
        XCTAssertTrue(plan.shouldRequestTransientRecovery)
        XCTAssertEqual(plan.transientRetryDirective, .schedule(.deferReveal))
        let applicationPlan = plan.applicationPlan(didScheduleTransientRecovery: false)
        XCTAssertFalse(applicationPlan.shouldHide)
        XCTAssertTrue(applicationPlan.shouldDeferReveal)
        XCTAssertEqual(applicationPlan.transientRecoveryReason, .deferReveal)
        XCTAssertEqual(applicationPlan.transientRetryDirective, .schedule(.deferReveal))
        XCTAssertTrue(applicationPlan.visibilityTransition.shouldDeferReveal)
        XCTAssertFalse(applicationPlan.visibilityTransition.shouldRevealHostedView)
    }

    func testFrameLossPlanSkipsTransientReasonForHiddenTargets() {
        let plan = TerminalLifecycleExecutor.frameLossPlan(
            context: TerminalLifecycleExecutorFrameVisibilityContext(
                transientRecoveryEnabled: true,
                targetVisible: false,
                hostedHidden: true,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                revealReadyForDisplay: true
            )
        )

        XCTAssertTrue(plan.shouldHide)
        XCTAssertFalse(plan.shouldDeferReveal)
        XCTAssertNil(plan.transientRecoveryReason)
        XCTAssertFalse(plan.shouldRequestTransientRecovery)
        XCTAssertEqual(plan.transientRetryDirective, .reset)
        XCTAssertEqual(
            plan.hiddenStateAction(didScheduleTransientRecovery: true),
            .unmountHostedView
        )
    }

    func testFrameLossApplicationPlanPreservesVisibleDuringScheduledTransientRecovery() {
        let plan = TerminalLifecycleExecutor.frameLossPlan(
            context: TerminalLifecycleExecutorFrameVisibilityContext(
                transientRecoveryEnabled: true,
                targetVisible: true,
                hostedHidden: false,
                anchorHidden: true,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                revealReadyForDisplay: false
            )
        )

        let applicationPlan = plan.applicationPlan(didScheduleTransientRecovery: true)

        XCTAssertTrue(applicationPlan.shouldHide)
        XCTAssertEqual(applicationPlan.transientRetryDirective, .schedule(.anchorHidden))
        XCTAssertEqual(applicationPlan.hiddenStateAction, .preserveVisible)
        XCTAssertTrue(applicationPlan.visibilityTransition.shouldPreserveVisibleOnTransientLoss)
        XCTAssertEqual(applicationPlan.transientRecoveryReason, .anchorHidden)
    }

    func testFrameLossApplicationPlanCarriesResetDirectiveForHiddenTargets() {
        let plan = TerminalLifecycleExecutor.frameLossPlan(
            context: TerminalLifecycleExecutorFrameVisibilityContext(
                transientRecoveryEnabled: true,
                targetVisible: false,
                hostedHidden: true,
                anchorHidden: false,
                hasFiniteFrame: true,
                outsideHostBounds: false,
                tinyFrame: false,
                revealReadyForDisplay: true
            )
        )

        let applicationPlan = plan.applicationPlan(didScheduleTransientRecovery: false)

        XCTAssertTrue(applicationPlan.shouldHide)
        XCTAssertEqual(applicationPlan.transientRetryDirective, .reset)
        XCTAssertEqual(applicationPlan.hiddenStateAction, .unmountHostedView)
        XCTAssertFalse(applicationPlan.visibilityTransition.shouldRevealHostedView)
    }

    func testHiddenStateActionPreservesVisibleDuringScheduledTransientRecovery() {
        let action = TerminalLifecycleExecutor.hiddenStateAction(
            targetVisible: true,
            hostedHidden: false,
            didScheduleTransientRecovery: true
        )

        XCTAssertEqual(action, .preserveVisible)
    }

    func testHiddenStateActionHidesVisibleTargetWithoutScheduledRecovery() {
        let action = TerminalLifecycleExecutor.hiddenStateAction(
            targetVisible: true,
            hostedHidden: false,
            didScheduleTransientRecovery: false
        )

        XCTAssertEqual(action, .hideHostedView)
    }

    func testHiddenStateActionUnmountsHiddenTargets() {
        let action = TerminalLifecycleExecutor.hiddenStateAction(
            targetVisible: false,
            hostedHidden: true,
            didScheduleTransientRecovery: false
        )

        XCTAssertEqual(action, .unmountHostedView)
    }

    func testFrameGeometryApplicationPlanRequestsFrameUpdateAndRefreshWhenTargetFrameChanges() {
        let plan = TerminalLifecycleExecutor.frameGeometryApplicationPlan(
            hasFiniteFrame: true,
            oldFrame: NSRect(x: 0, y: 0, width: 100, height: 80),
            targetFrame: NSRect(x: 10, y: 12, width: 140, height: 90),
            currentBounds: NSRect(x: 0, y: 0, width: 100, height: 80)
        )

        XCTAssertTrue(plan.shouldApplyFrame)
        XCTAssertTrue(plan.shouldApplyBounds)
        XCTAssertTrue(plan.shouldReconcileGeometry)
        XCTAssertEqual(plan.refreshReason, .portalFrameChange)
    }

    func testFrameGeometryApplicationPlanSkipsWorkForApproximateFrameAndBoundsMatch() {
        let plan = TerminalLifecycleExecutor.frameGeometryApplicationPlan(
            hasFiniteFrame: true,
            oldFrame: NSRect(x: 10, y: 12, width: 140, height: 90),
            targetFrame: NSRect(x: 10.2, y: 12.2, width: 140.2, height: 90.2),
            currentBounds: NSRect(x: 0, y: 0, width: 140.2, height: 90.2)
        )

        XCTAssertFalse(plan.shouldApplyFrame)
        XCTAssertFalse(plan.shouldApplyBounds)
        XCTAssertFalse(plan.shouldReconcileGeometry)
        XCTAssertNil(plan.refreshReason)
    }

    func testFrameGeometryApplicationPlanSkipsNonFiniteFrameWork() {
        let plan = TerminalLifecycleExecutor.frameGeometryApplicationPlan(
            hasFiniteFrame: false,
            oldFrame: NSRect(x: 0, y: 0, width: 100, height: 80),
            targetFrame: NSRect(x: 10, y: 12, width: 140, height: 90),
            currentBounds: NSRect(x: 0, y: 0, width: 100, height: 80)
        )

        XCTAssertFalse(plan.shouldApplyFrame)
        XCTAssertFalse(plan.shouldApplyBounds)
        XCTAssertFalse(plan.shouldReconcileGeometry)
        XCTAssertNil(plan.refreshReason)
    }

    func testRevealApplicationPlanRequestsGeometryAndRefreshWhenRevealIsNeeded() {
        let transition = TerminalLifecycleExecutorVisibilityTransitionDecision(
            shouldPreserveVisibleOnTransientLoss: false,
            shouldDeferReveal: false,
            shouldRevealHostedView: true
        )

        let plan = TerminalLifecycleExecutor.revealApplicationPlan(
            visibilityTransition: transition
        )

        XCTAssertTrue(plan.shouldRevealHostedView)
        XCTAssertTrue(plan.shouldReconcileGeometry)
        XCTAssertEqual(plan.refreshReason, .portalReveal)
    }

    func testRevealApplicationPlanSkipsGeometryAndRefreshWhenRevealIsNotNeeded() {
        let transition = TerminalLifecycleExecutorVisibilityTransitionDecision(
            shouldPreserveVisibleOnTransientLoss: false,
            shouldDeferReveal: true,
            shouldRevealHostedView: false
        )

        let plan = TerminalLifecycleExecutor.revealApplicationPlan(
            visibilityTransition: transition
        )

        XCTAssertFalse(plan.shouldRevealHostedView)
        XCTAssertFalse(plan.shouldReconcileGeometry)
        XCTAssertNil(plan.refreshReason)
    }

    func testBindSeedPlanUsesSeededFrameWhenAnchorGeometryIsReady() {
        let seededFrame = NSRect(x: 12, y: 18, width: 140, height: 96)

        let plan = TerminalLifecycleExecutor.bindSeedPlan(
            seededFrame: seededFrame
        )

        XCTAssertEqual(plan.frame, seededFrame)
        XCTAssertEqual(plan.bounds, NSRect(origin: .zero, size: seededFrame.size))
        XCTAssertFalse(plan.shouldHideHostedView)
        XCTAssertTrue(plan.shouldReconcileGeometry)
    }

    func testBindSeedPlanFallsBackToHiddenZeroFrameWhenAnchorGeometryIsMissing() {
        let plan = TerminalLifecycleExecutor.bindSeedPlan(
            seededFrame: nil
        )

        XCTAssertEqual(plan.frame, .zero)
        XCTAssertEqual(plan.bounds, .zero)
        XCTAssertTrue(plan.shouldHideHostedView)
        XCTAssertTrue(plan.shouldReconcileGeometry)
    }

    func testExternalGeometryApplicationPlanRequestsRefreshWhenReconcileChangedGeometry() {
        let plan = TerminalLifecycleExecutor.externalGeometryApplicationPlan(
            didReconcileGeometry: true
        )

        XCTAssertEqual(plan.refreshReason, .portalExternalGeometrySync)
    }

    func testExternalGeometryApplicationPlanSkipsRefreshWhenReconcileDidNotChangeGeometry() {
        let plan = TerminalLifecycleExecutor.externalGeometryApplicationPlan(
            didReconcileGeometry: false
        )

        XCTAssertNil(plan.refreshReason)
    }

    private func makeCurrentTerminalRecord(
        panelId: UUID = UUID(),
        workspaceId: UUID = UUID(),
        state: PanelLifecycleState,
        residency: PanelResidency,
        activeWindowMembership: Bool,
        desiredActive: Bool,
        responderEligible: Bool,
        accessibilityParticipation: Bool
    ) -> PanelLifecycleRecordSnapshot {
        PanelLifecycleRecordSnapshot(
            panelId: panelId,
            workspaceId: workspaceId,
            paneId: UUID(),
            tabId: UUID(),
            panelType: .terminal,
            generation: 5,
            state: state,
            residency: residency,
            mountedWorkspace: true,
            selectedWorkspace: desiredActive,
            retiringWorkspace: false,
            selectedInPane: true,
            desiredVisible: activeWindowMembership,
            desiredActive: desiredActive,
            activeWindowMembership: activeWindowMembership,
            responderEligible: responderEligible,
            accessibilityParticipation: accessibilityParticipation,
            backendProfile: PanelLifecycleShadowMapper.backendProfile(for: .terminal),
            anchor: nil
        )
    }

    private func makeDesiredTerminalRecord(
        panelId: UUID = UUID(),
        workspaceId: UUID = UUID(),
        targetState: PanelLifecycleState,
        targetResidency: PanelResidency,
        targetVisible: Bool,
        targetActive: Bool,
        targetResponderEligible: Bool,
        targetAccessibilityParticipation: Bool,
        requiresCurrentGenerationAnchor: Bool,
        anchorReadyForVisibility: Bool
    ) -> PanelLifecycleDesiredRecordSnapshot {
        PanelLifecycleDesiredRecordSnapshot(
            panelId: panelId,
            workspaceId: workspaceId,
            panelType: .terminal,
            generation: 5,
            targetState: targetState,
            targetResidency: targetResidency,
            targetVisible: targetVisible,
            targetActive: targetActive,
            targetWindowNumber: targetVisible ? 41 : nil,
            targetAnchorId: targetVisible ? UUID() : nil,
            targetResponderEligible: targetResponderEligible,
            targetAccessibilityParticipation: targetAccessibilityParticipation,
            requiresCurrentGenerationAnchor: requiresCurrentGenerationAnchor,
            anchorReadyForVisibility: anchorReadyForVisibility
        )
    }

    private func makeBinding(
        panelId: UUID,
        anchorId: UUID? = UUID(),
        windowNumber: Int?,
        visibleInUI: Bool,
        hostedHidden: Bool,
        attachedToPortalHost: Bool,
        guardGeneration: UInt64?
    ) -> TerminalLifecycleExecutorBindingSnapshot {
        TerminalLifecycleExecutorBindingSnapshot(
            panelId: panelId,
            anchorId: anchorId,
            windowNumber: windowNumber,
            anchorWindowNumber: windowNumber,
            visibleInUI: visibleInUI,
            hostedHidden: hostedHidden,
            attachedToPortalHost: attachedToPortalHost,
            zPriority: 0,
            guardGeneration: guardGeneration,
            guardState: "ready"
        )
    }
}
