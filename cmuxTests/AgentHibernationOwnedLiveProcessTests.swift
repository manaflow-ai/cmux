import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentHibernationOwnedLiveProcessTests {
    private let pid = 4_242

    @Test
    func exactIdleHookOwnerIsEligible() {
        let agent = snapshot(sessionId: "owned-idle")
        let identity = processIdentity(startSeconds: 100)
        let observation = entry(
            snapshot: agent,
            lifecycle: .idle,
            hasHookRestoreAuthority: true,
            processIDs: [pid],
            agentProcessIdentities: [pid: identity]
        )

        #expect(
            AgentHibernationLiveProcessEvidence.resolve(
                observation: observation,
                agent: agent
            ).ownership == .ownedIdleRestorableSession
        )
    }

    @Test
    func processOnlyActiveNeedsInputAndMissingIdentityFailClosed() {
        let agent = snapshot(sessionId: "fail-closed")
        let identity = processIdentity(startSeconds: 100)
        let cases = [
            entry(
                snapshot: agent,
                lifecycle: .idle,
                hasHookRestoreAuthority: false,
                processIDs: [pid],
                agentProcessIdentities: [pid: identity]
            ),
            // Active workloads project to the durable `.running` lifecycle.
            entry(
                snapshot: agent,
                lifecycle: .running,
                hasHookRestoreAuthority: true,
                processIDs: [pid],
                agentProcessIdentities: [pid: identity]
            ),
            entry(
                snapshot: agent,
                lifecycle: .needsInput,
                hasHookRestoreAuthority: true,
                processIDs: [pid],
                agentProcessIdentities: [pid: identity]
            ),
            entry(
                snapshot: agent,
                lifecycle: .idle,
                hasHookRestoreAuthority: true,
                processIDs: [pid],
                agentProcessIdentities: [:]
            ),
        ]

        for observation in cases {
            let evidence = AgentHibernationLiveProcessEvidence.resolve(
                observation: observation,
                agent: agent
            )
            #expect(evidence.ownership == .unverified)
            #expect(evidence.allowsHibernation == false)
        }
    }

    @Test
    func sessionMismatchFailsClosed() {
        let recorded = snapshot(sessionId: "recorded")
        let current = snapshot(sessionId: "current")
        let identity = processIdentity(startSeconds: 100)
        let observation = entry(
            snapshot: current,
            lifecycle: .idle,
            hasHookRestoreAuthority: true,
            processIDs: [pid],
            agentProcessIdentities: [pid: identity]
        )

        let evidence = AgentHibernationLiveProcessEvidence.resolve(
            observation: observation,
            agent: recorded
        )
        #expect(evidence.ownership == .unverified)
        #expect(evidence.allowsHibernation == false)
    }

    @Test
    func plannerRejectsUnverifiedAndNonIdleOwnedLiveProcesses() {
        let workspaceId = UUID()
        let now: TimeInterval = 1_000
        let identity = processIdentity(startSeconds: 100)
        let owned = AgentHibernationLiveProcessEvidence.ownedIdleRestorableSession(
            processIDs: [pid],
            processIdentities: [pid: identity]
        )
        let unverified = AgentHibernationLiveProcessEvidence.unverified(processIDs: [pid])
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 1,
            confirmationSeconds: 5
        )

        for (evidence, lifecycle) in [
            (unverified, AgentHibernationLifecycleState.idle),
            (owned, AgentHibernationLifecycleState.running),
            (owned, AgentHibernationLifecycleState.needsInput),
        ] {
            let candidate = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
            let protected = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
            let selected = AgentHibernationPlanner.selectedPanelKeys(
                inputs: [
                    .init(
                        key: candidate,
                        hasRestorableAgent: true,
                        isLive: true,
                        liveProcessEvidence: evidence,
                        isProtected: false,
                        lifecycle: lifecycle,
                        hasUnconfirmedTerminalInput: false,
                        lastActivityAt: now - 300
                    ),
                    .init(
                        key: protected,
                        hasRestorableAgent: true,
                        isLive: true,
                        isProtected: true,
                        lifecycle: .idle,
                        hasUnconfirmedTerminalInput: false,
                        lastActivityAt: now - 300
                    ),
                ],
                settings: settings,
                now: now
            )
            #expect(selected.isEmpty)
        }
    }

    @Test
    func pidReuseChangesFingerprintAndFailsImmediateIdentityCheck() {
        let original = processIdentity(startSeconds: 100)
        let reused = processIdentity(startSeconds: 101)
        let originalFingerprint = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [pid],
            processIdentities: [pid: original]
        )
        let reusedFingerprint = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [pid],
            processIdentities: [pid: reused]
        )

        #expect(originalFingerprint != reusedFingerprint)
        #expect(AgentHibernationController.processIdentitiesStillMatch(
            [pid: original],
            currentIdentity: { _ in original }
        ))
        #expect(!AgentHibernationController.processIdentitiesStillMatch(
            [pid: original],
            currentIdentity: { _ in reused }
        ))
        #expect(!AgentHibernationController.processIdentitiesStillMatch(
            [pid: original],
            currentIdentity: { _ in nil }
        ))
    }

    @Test
    func postSnapshotEvidenceRejectsPIDGenerationAndProcessSetDrift() {
        let agent = snapshot(sessionId: "post-snapshot")
        let original = processIdentity(startSeconds: 100)
        let reused = processIdentity(startSeconds: 101)
        let recorded = AgentHibernationLiveProcessEvidence.resolve(
            observation: entry(
                snapshot: agent,
                lifecycle: .idle,
                hasHookRestoreAuthority: true,
                processIDs: [pid],
                agentProcessIdentities: [pid: original]
            ),
            agent: agent
        )
        let exact = entry(
            snapshot: agent,
            lifecycle: .idle,
            hasHookRestoreAuthority: true,
            processIDs: [pid],
            agentProcessIdentities: [pid: original]
        )
        let reusedPID = entry(
            snapshot: agent,
            lifecycle: .idle,
            hasHookRestoreAuthority: true,
            processIDs: [pid],
            agentProcessIdentities: [pid: reused]
        )
        let addedProcess = entry(
            snapshot: agent,
            lifecycle: .idle,
            hasHookRestoreAuthority: true,
            processIDs: [pid, pid + 1],
            agentProcessIdentities: [pid: original]
        )

        #expect(recorded.matchesPostSnapshot(observation: exact, agent: agent))
        #expect(!recorded.matchesPostSnapshot(observation: reusedPID, agent: agent))
        #expect(!recorded.matchesPostSnapshot(observation: addedProcess, agent: agent))
    }

    @Test
    func nonAgentScopedPIDReuseFailsPostSnapshotAndImmediateChecks() {
        let agent = snapshot(sessionId: "scoped-child-reuse")
        let childPID = pid + 1
        let root = processIdentity(startSeconds: 100)
        let child = processIdentity(pid: childPID, startSeconds: 100)
        let reusedChild = processIdentity(pid: childPID, startSeconds: 101)
        let recordedObservation = entry(
            snapshot: agent,
            lifecycle: .idle,
            hasHookRestoreAuthority: true,
            processIDs: [pid, childPID],
            agentProcessIdentities: [pid: root],
            processIdentities: [pid: root, childPID: child]
        )
        let recorded = AgentHibernationLiveProcessEvidence.resolve(
            observation: recordedObservation,
            agent: agent
        )
        let reusedObservation = entry(
            snapshot: agent,
            lifecycle: .idle,
            hasHookRestoreAuthority: true,
            processIDs: [pid, childPID],
            agentProcessIdentities: [pid: root],
            processIdentities: [pid: root, childPID: reusedChild]
        )

        #expect(recorded.ownership == .ownedIdleRestorableSession)
        #expect(!recorded.matchesPostSnapshot(observation: reusedObservation, agent: agent))
        #expect(!AgentHibernationController.processIdentitiesStillMatch(
            recorded.processIdentities,
            currentIdentity: { candidate in
                candidate == pid_t(self.pid) ? root : reusedChild
            }
        ))
    }

    private func snapshot(sessionId: String) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: "/tmp/cmux-hibernation",
            launchCommand: nil
        )
    }

    private func processIdentity(pid: Int? = nil, startSeconds: Int64) -> AgentPIDProcessIdentity {
        AgentPIDProcessIdentity(
            pid: pid_t(pid ?? self.pid),
            startSeconds: startSeconds,
            startMicroseconds: 500
        )
    }

    private func entry(
        snapshot: SessionRestorableAgentSnapshot,
        lifecycle: AgentHibernationLifecycleState,
        hasHookRestoreAuthority: Bool,
        processIDs: Set<Int>,
        agentProcessIdentities: [Int: AgentPIDProcessIdentity],
        processIdentities: [Int: AgentPIDProcessIdentity]? = nil
    ) -> RestorableAgentSessionIndex.Entry {
        RestorableAgentSessionIndex.Entry(
            snapshot: snapshot,
            lifecycle: lifecycle,
            updatedAt: 100,
            processIDs: processIDs,
            agentProcessIDs: [pid],
            agentProcessIdentities: agentProcessIdentities,
            processIdentities: processIdentities ?? agentProcessIdentities,
            hasHookRestoreAuthority: hasHookRestoreAuthority
        )
    }
}
