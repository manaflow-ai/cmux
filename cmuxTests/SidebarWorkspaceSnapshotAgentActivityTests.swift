import CmuxSidebar
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class SidebarAgentElapsedClockTestTarget: SidebarAgentElapsedClockTarget {
    private(set) var receivedDates: [Date] = []

    func sidebarAgentElapsedClockDidTick(at now: Date) {
        receivedDates.append(now)
    }
}

extension SidebarWorkspaceSnapshotRefreshPolicyTests {
    @MainActor
    @Test func workspaceAgentSpinnerFeatureFlagDefaultsOff() throws {
        let definition = try #require(CmuxFeatureFlags.allFlags.first {
            $0.key == "sidebar-workspace-agent-spinner-experiment"
        })
        let suiteName = "cmux.feature.flags.sidebar-workspace-agent-spinner.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })

        #expect(!flags.effectiveValue(for: definition))
    }

    @Test func contextMenuAgentActivityChangeUpdatesDisplayedSpinnerImmediately() {
        let current = Self.snapshot(
            latestConversationMessage: "old message"
        )
        let next = Self.snapshot(
            latestConversationMessage: "new message",
            agentActivity: SidebarWorkspaceAgentActivity(agents: [
                SidebarAgentActivity(
                    id: "test-running-agent",
                    statusKey: "codex",
                    state: .running,
                    startedAt: 1
                ),
            ])
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage?.activeCodingAgentCount == 1)
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
        #expect(decision.pendingWorkspaceSnapshot == next)
        #expect(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    @Test func presentationKeyChangesWhenAgentActivityVisibilityChanges() {
        let hidden = Self.presentationKey(showsAgentActivity: false)
        let visible = Self.presentationKey(showsAgentActivity: true)

        #expect(hidden != visible)
        #expect(!hidden.showsAgentActivity)
        #expect(visible.showsAgentActivity)
    }

    @MainActor
    @Test func presentationKeyTracksLegacySpinnerSeparatelyFromActivityLabel() {
        let suiteName = "cmux.sidebar.agent-activity.presentation-key.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let spinnerHidden = SidebarWorkspaceSnapshotFactory.presentationKey(
            settings: settings,
            showsAgentActivity: true,
            showsAgentSpinner: false
        )
        let spinnerVisible = SidebarWorkspaceSnapshotFactory.presentationKey(
            settings: settings,
            showsAgentActivity: true,
            showsAgentSpinner: true
        )

        #expect(spinnerHidden != spinnerVisible)
        #expect(spinnerHidden.showsAgentActivity)
        #expect(!spinnerHidden.showsAgentSpinner)
        #expect(spinnerVisible.showsAgentSpinner)
    }

    @Test func disabledSpinnerDoesNotReadAgentLifecycleStates() {
        var didReadAgentLifecycleStates = false
        let agentLifecycleStates: () -> [UUID: [String: AgentHibernationLifecycleState]] = {
            didReadAgentLifecycleStates = true
            return [
                UUID(): [
                    "codex": .running,
                    "claude_code": .running,
                ],
            ]
        }

        let count = SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
            showsAgentActivity: false,
            statesByPanelId: agentLifecycleStates()
        )

        #expect(count == 0)
        #expect(!didReadAgentLifecycleStates)
    }
}

struct SidebarWorkspaceAgentActivityTests {
    private static let codexPanelID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let claudePanelID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let ampPanelID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private static let cursorPanelID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    @MainActor
    @Test
    func elapsedClockRunsOnlyWhileARealizedTargetIsRegistered() {
        let clock = SidebarAgentElapsedClock()
        let target = SidebarAgentElapsedClockTestTarget()
        let tickDate = Date(timeIntervalSince1970: 123)

        clock.actions.register(target)
        clock.tick(at: tickDate)
        #expect(target.receivedDates == [tickDate])

        clock.actions.unregister(target)
        clock.tick(at: Date(timeIntervalSince1970: 124))
        #expect(target.receivedDates == [tickDate])
    }

    @MainActor
    @Test
    func elapsedDisplayCacheReusesPayloadWithinOneCompactBucket() {
        let cache = SidebarAgentActivityDisplayCache()
        let activity = SidebarWorkspaceAgentActivity(agents: [
            SidebarAgentActivity(
                id: "running-agent",
                statusKey: "codex",
                state: .running,
                startedAt: 100
            ),
        ])

        let first = cache.payload(
            for: activity,
            at: Date(timeIntervalSince1970: 110.1)
        )
        let second = cache.payload(
            for: activity,
            at: Date(timeIntervalSince1970: 110.9)
        )

        #expect(first == second)
    }

    @Test
    func manualWorkspaceLoadersContributeToSpinnerCountWithoutAgentLabels() {
        let activity = SidebarWorkspaceAgentActivity(
            agents: [],
            manualLoadingCount: 2
        )

        #expect(activity.manualLoadingCount == 2)
        #expect(activity.activeCodingAgentCount == 2)
        #expect(activity.agents.isEmpty)
    }

    @Test
    func hourRangeElapsedBucketKeepsMinutePrecision() {
        #expect(
            SidebarWorkspaceAgentActivity.compactElapsedDisplayBucket(3_600)
                != SidebarWorkspaceAgentActivity.compactElapsedDisplayBucket(3_660)
        )
    }

    private static func evidence(
        panelID: UUID = codexPanelID,
        statusKey: String = "codex",
        generation: SidebarAgentActivityEvidence.Generation = .session("session-1"),
        lifecycle: AgentHibernationLifecycleState?,
        startedAt: TimeInterval? = 1_000,
        updatedAt: TimeInterval? = nil,
        processLiveness: RestorableAgentProcessLiveness = .running,
        hasExactProcessIdentity: Bool = true,
        isRuntimeBound: Bool = true,
        hasLiveLifecycleSignal: Bool = true,
        isHookBacked: Bool = false,
        isExactProcessBinding: Bool = true,
        isHeuristicProcessDetection: Bool = false
    ) -> SidebarAgentActivityEvidence {
        SidebarAgentActivityEvidence(
            panelID: panelID,
            statusKey: statusKey,
            generation: generation,
            lifecycle: lifecycle,
            startedAt: startedAt,
            updatedAt: updatedAt ?? startedAt,
            processLiveness: processLiveness,
            hasExactProcessIdentity: hasExactProcessIdentity,
            isRuntimeBound: isRuntimeBound,
            hasLiveLifecycleSignal: hasLiveLifecycleSignal,
            isHookBacked: isHookBacked,
            isExactProcessBinding: isExactProcessBinding,
            isHeuristicProcessDetection: isHeuristicProcessDetection
        )
    }

    @Test(arguments: zip(
        [Self.codexPanelID, Self.claudePanelID, Self.ampPanelID, Self.cursorPanelID],
        ["codex", "claude_code", "amp", "cursor"]
    ))
    func deterministicHookEventSequenceResolvesEachTrackedAgent(
        panelID: UUID,
        statusKey: String
    ) {
        let generation = SidebarAgentActivityEvidence.Generation.session("\(statusKey)-session")
        let running = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                panelID: panelID,
                statusKey: statusKey,
                generation: generation,
                lifecycle: .running
            )
        ])
        let needsInput = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                panelID: panelID,
                statusKey: statusKey,
                generation: generation,
                lifecycle: .needsInput
            )
        ])
        let idle = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                panelID: panelID,
                statusKey: statusKey,
                generation: generation,
                lifecycle: .idle
            )
        ])

        #expect(running.activity(forStatusKey: statusKey)?.state == .running)
        #expect(needsInput.activity(forStatusKey: statusKey)?.state == .needsInput)
        #expect(idle.activity(forStatusKey: statusKey)?.state == .idle)
    }

    @Test
    func elapsedRecomputesFromPersistedAnchorAfterRestart() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                lifecycle: .running,
                startedAt: 10,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: true
            )
        ])

        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 610)) == "10m")
        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 3_670)) == "1h 1m")
    }

    @Test
    func sameSessionRuntimeKeepsDurableHookAnchor() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                generation: .session("same-session"),
                lifecycle: .running,
                startedAt: 100,
                processLiveness: .unknown,
                hasExactProcessIdentity: false,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: true,
                isExactProcessBinding: false
            ),
            Self.evidence(
                generation: .session("same-session"),
                lifecycle: .running,
                startedAt: 400
            ),
        ])

        #expect(activity.agents.count == 1)
        #expect(activity.primaryState == .running)
        #expect(activity.primaryElapsedStart == 100)
        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 700)) == "10m")
    }

    @Test
    func lifecycleOnlyRuntimeSharesTheCachedSessionGeneration() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                generation: .session("lifecycle-session"),
                lifecycle: .running,
                startedAt: 100,
                processLiveness: .unknown,
                hasExactProcessIdentity: false,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: true,
                isExactProcessBinding: false
            ),
            Self.evidence(
                generation: .session("lifecycle-session"),
                lifecycle: .needsInput,
                startedAt: nil,
                processLiveness: .unknown,
                hasExactProcessIdentity: false,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: true,
                isHookBacked: false,
                isExactProcessBinding: false
            ),
        ])

        #expect(activity.agents.count == 1)
        #expect(activity.primaryState == .needsInput)
        #expect(activity.primaryElapsedStart == nil)
    }

    @Test
    func hookAnchorWinsOverAnEarlierRuntimeAnchorByProvenancePriority() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                generation: .session("priority-session"),
                lifecycle: .running,
                startedAt: 400,
                processLiveness: .unknown,
                hasExactProcessIdentity: false,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: true,
                isExactProcessBinding: false
            ),
            Self.evidence(
                generation: .session("priority-session"),
                lifecycle: .running,
                startedAt: 100
            ),
        ])

        #expect(activity.primaryElapsedStart == 400)
        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 700)) == "5m")
    }

    @Test
    func staleSessionCannotDonateElapsedAnchorToNewRuntimeGeneration() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                generation: .session("old-session"),
                lifecycle: .running,
                startedAt: 100,
                processLiveness: .exited,
                hasExactProcessIdentity: false,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: true,
                isExactProcessBinding: false
            ),
            Self.evidence(
                generation: .session("new-session"),
                lifecycle: .running,
                startedAt: 400
            ),
        ])

        #expect(activity.primaryState == .running)
        #expect(activity.primaryElapsedStart == 400)
        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 700)) == "5m")
    }

    @Test
    func liveTokenRoutedLifecycleIsAuthoritativeWithoutPidConfirmation() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                generation: .lifecycle,
                lifecycle: .needsInput,
                startedAt: nil,
                processLiveness: .unknown,
                hasExactProcessIdentity: false,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: true,
                isHookBacked: false,
                isExactProcessBinding: false
            )
        ])

        #expect(activity.agents.count == 1)
        #expect(activity.primaryState == .needsInput)
    }

    @Test
    func needsInputOutranksRunningForCompactPresentation() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(lifecycle: .running),
            Self.evidence(
                panelID: Self.claudePanelID,
                statusKey: "claude_code",
                generation: .session("claude-session"),
                lifecycle: .needsInput
            ),
        ])

        #expect(activity.primaryState == .needsInput)
        #expect(activity.activeCodingAgentCount == 1)
    }

    @Test
    func correctedStatusEntriesChoosesOneMostActionableAgentPerStatusKey() {
        let activity = SidebarWorkspaceAgentActivity(agents: [
            SidebarAgentActivity(
                id: "codex-running",
                statusKey: "codex",
                state: .running,
                startedAt: 100
            ),
            SidebarAgentActivity(
                id: "codex-needs-input",
                statusKey: "codex",
                state: .needsInput,
                startedAt: nil
            ),
        ])

        let corrected = activity.correctedStatusEntries([
            SidebarStatusEntry(key: "codex", value: "Running")
        ])

        #expect(corrected.count == 1)
        #expect(corrected.first?.value == SidebarWorkspaceAgentActivity.localizedStateLabel(.needsInput))
    }

    @Test
    func sessionAnchorClampsFutureClockToZero() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(lifecycle: .running, startedAt: 500)
        ])

        #expect(activity.primaryElapsedStart == 500)
        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 450)) == "0s")
        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 560)) == "1m")
    }

    @Test
    func noDeterministicPresenceDoesNotCreateAnAgentRow() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                lifecycle: .running,
                processLiveness: .running,
                hasExactProcessIdentity: true,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: false,
                isExactProcessBinding: false
            )
        ])

        #expect(activity.agents.isEmpty)
        #expect(activity.primaryState == nil)
        #expect(activity.activeCodingAgentCount == 0)
        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 10_000)) == nil)
    }

    @Test
    func hookBackedHeuristicProcessEvidenceIsPresentedAsUnknown() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                lifecycle: .running,
                processLiveness: .running,
                hasExactProcessIdentity: true,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: true,
                isExactProcessBinding: false,
                isHeuristicProcessDetection: true
            )
        ])

        #expect(activity.agents.count == 1)
        #expect(activity.primaryState == .unknown)
        #expect(activity.activeCodingAgentCount == 0)
    }

    @Test
    func exactProcessBindingWithoutLifecycleIsUnknown() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                lifecycle: nil,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: false
            )
        ])

        #expect(activity.primaryState == .unknown)
        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 1_100)) == nil)
    }

    @Test
    func persistedLifecycleWithoutLiveProcessIsUnknown() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                lifecycle: .running,
                processLiveness: .unknown,
                hasExactProcessIdentity: false,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: true,
                isExactProcessBinding: false
            )
        ])

        #expect(activity.agents.count == 1)
        #expect(activity.primaryState == .unknown)
    }

    @Test
    func staleStructuredStatusWithoutDeterministicPresenceIsHidden() {
        let stale = SidebarStatusEntry(key: "codex", value: "Running")
        let unrelated = SidebarStatusEntry(key: "build", value: "Compiling")

        let corrected = SidebarWorkspaceAgentActivity(agents: [])
            .correctedStatusEntries([stale, unrelated])

        #expect(corrected.map(\.key) == ["build"])
    }

    @Test
    func deterministicPresenceWithoutLifecycleCorrectsStatusToUnknown() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                lifecycle: nil,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: false
            )
        ])

        let corrected = activity.correctedStatusEntries([
            SidebarStatusEntry(key: "codex", value: "Running")
        ])

        #expect(corrected.count == 1)
        #expect(corrected.first?.value == SidebarWorkspaceAgentActivity.localizedStateLabel(.unknown))
        #expect(corrected.first?.icon == "questionmark.circle")
    }

    @Test
    func exitedNeedsInputEvidenceBecomesUnknown() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                lifecycle: .needsInput,
                processLiveness: .exited,
                hasExactProcessIdentity: false,
                isRuntimeBound: false,
                hasLiveLifecycleSignal: false,
                isHookBacked: true,
                isExactProcessBinding: false
            )
        ])

        #expect(activity.primaryState == .unknown)
    }

    @Test
    func exitedIdleEvidenceBecomesUnknown() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(
                lifecycle: .idle,
                processLiveness: .exited,
                hasExactProcessIdentity: false,
                isRuntimeBound: true,
                hasLiveLifecycleSignal: true,
                isHookBacked: false,
                isExactProcessBinding: true
            )
        ])

        #expect(activity.primaryState == .unknown)
    }

    @Test
    func runningWithoutStartAnchorHasNoElapsedText() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(lifecycle: .running, startedAt: nil)
        ])

        #expect(activity.primaryState == .running)
        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 10_000)) == nil)
    }

    @Test
    func invalidElapsedAnchorsAndFormatterInputsRemainIndeterminateOrBounded() {
        let activity = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(lifecycle: .running, startedAt: .nan)
        ])

        #expect(activity.primaryElapsedStart == nil)
        #expect(activity.elapsedText(at: Date(timeIntervalSince1970: 10_000)) == nil)
        #expect(SidebarWorkspaceAgentActivity.compactElapsedText(seconds: .infinity) == "0s")
        #expect(SidebarWorkspaceAgentActivity.compactElapsedDisplayBucket(.infinity) == 0)
    }

    @Test
    func legacyHookRecordWithoutStartAnchorStillDecodes() throws {
        let data = try #require(
            """
            {
              "sessionId": "legacy-session",
              "workspaceId": "00000000-0000-0000-0000-000000000001",
              "surfaceId": "00000000-0000-0000-0000-000000000002",
              "updatedAt": 123
            }
            """.data(using: .utf8)
        )

        let record = try JSONDecoder().decode(RestorableAgentHookSessionRecord.self, from: data)

        #expect(record.startedAt == nil)
        #expect(record.updatedAt == 123)
    }

    @Test
    func contextMenuAgentStateChangeUpdatesEvenWhenRunningCountIsUnchanged() {
        let running = SidebarWorkspaceAgentActivity.resolve(evidence: [
            Self.evidence(lifecycle: .running)
        ])
        let needsInputAndRunning = SidebarWorkspaceAgentActivity(agents: [
            SidebarAgentActivity(
                id: "needs-input-agent",
                statusKey: "codex",
                state: .needsInput,
                startedAt: nil
            ),
            SidebarAgentActivity(
                id: "running-agent",
                statusKey: "claude_code",
                state: .running,
                startedAt: 1_000
            ),
        ])
        let current = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(
            latestConversationMessage: "old message",
            agentActivity: running
        )
        let next = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(
            latestConversationMessage: "new message",
            agentActivity: needsInputAndRunning
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage?.agentActivity.primaryState == .needsInput)
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
        #expect(decision.pendingWorkspaceSnapshot == next)
    }
}
