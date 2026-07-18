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

    @Test
    func loaderMarksOnlyScopedLiveHookPIDAsAuthoritative() throws {
        let fixture = try hookFixture(sessionId: "pure-hook", pid: pid)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let identity = processIdentity(startSeconds: 100)

        let index = loadIndex(
            fixture: fixture,
            processArgumentsProvider: { requestedPID in
                requestedPID == self.pid ? self.scopedOpenCodeProcess(fixture: fixture) : nil
            },
            processIdentityProvider: { requestedPID in
                requestedPID == self.pid ? identity : nil
            }
        )
        let entry = try #require(index.entry(
            workspaceId: fixture.key.workspaceId,
            panelId: fixture.key.panelId
        ))

        #expect(entry.hasHookRestoreAuthority)
        #expect(entry.processIDs == [pid])
        #expect(entry.processIdentities == [pid: identity])
        #expect(
            AgentHibernationLiveProcessEvidence.resolve(
                observation: entry,
                agent: entry.snapshot
            ).ownership == .ownedIdleRestorableSession
        )
    }

    @Test
    func loaderPropagatesAuthorityForExactExplicitDetection() throws {
        let fixture = try hookFixture(sessionId: "explicit-exact")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let childPID = pid + 1
        let root = processIdentity(startSeconds: 100)
        let child = processIdentity(pid: childPID, startSeconds: 100)

        let index = loadIndex(
            fixture: fixture,
            detected: detected(
                fixture: fixture,
                sessionId: fixture.sessionId,
                processIDs: [pid, childPID],
                source: .explicit
            ),
            processIdentityProvider: { requestedPID in
                requestedPID == self.pid ? root : (requestedPID == childPID ? child : nil)
            }
        )
        let entry = try #require(index.entry(
            workspaceId: fixture.key.workspaceId,
            panelId: fixture.key.panelId
        ))

        #expect(entry.hasHookRestoreAuthority)
        #expect(entry.processIdentities == [pid: root, childPID: child])
        #expect(
            AgentHibernationLiveProcessEvidence.resolve(
                observation: entry,
                agent: entry.snapshot
            ).ownership == .ownedIdleRestorableSession
        )
    }

    @Test
    func loaderFailsClosedForBorrowedOrUnmatchedDetectedIdentity() throws {
        for source in [
            RestorableAgentSessionIndex.ProcessDetectedSessionIDSource.inferredLatestSessionFile,
            .forkParentFallback,
        ] {
            let fixture = try hookFixture(sessionId: "hook-\(source)", updatedAt: 200)
            defer { try? FileManager.default.removeItem(at: fixture.home) }
            let identity = processIdentity(startSeconds: 100)
            let index = loadIndex(
                fixture: fixture,
                detected: detected(
                    fixture: fixture,
                    sessionId: "detected-mismatch",
                    processIDs: [pid],
                    source: source
                ),
                processIdentityProvider: { requestedPID in
                    requestedPID == self.pid ? identity : nil
                }
            )
            let entry = try #require(index.entry(
                workspaceId: fixture.key.workspaceId,
                panelId: fixture.key.panelId
            ))

            #expect(!entry.hasHookRestoreAuthority)
            #expect(
                AgentHibernationLiveProcessEvidence.resolve(
                    observation: entry,
                    agent: entry.snapshot
                ).ownership == .unverified
            )
        }

        let unmatched = try hookFixture(sessionId: "unused-hook")
        try FileManager.default.removeItem(
            at: RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: unmatched.home.path)
        )
        defer { try? FileManager.default.removeItem(at: unmatched.home) }
        let unmatchedIndex = loadIndex(
            fixture: unmatched,
            detected: detected(
                fixture: unmatched,
                sessionId: "unmatched-detected",
                processIDs: [pid],
                source: .explicit
            ),
            processIdentityProvider: { requestedPID in
                requestedPID == self.pid ? self.processIdentity(startSeconds: 100) : nil
            }
        )
        let unmatchedEntry = try #require(unmatchedIndex.entry(
            workspaceId: unmatched.key.workspaceId,
            panelId: unmatched.key.panelId
        ))
        #expect(!unmatchedEntry.hasHookRestoreAuthority)
    }

    @Test
    func incompleteFullProcessIdentityCoverageFailsClosed() throws {
        let fixture = try hookFixture(sessionId: "incomplete-identities")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let childPID = pid + 1
        let root = processIdentity(startSeconds: 100)
        let index = loadIndex(
            fixture: fixture,
            detected: detected(
                fixture: fixture,
                sessionId: fixture.sessionId,
                processIDs: [pid, childPID],
                source: .explicit
            ),
            processIdentityProvider: { requestedPID in
                requestedPID == self.pid ? root : nil
            }
        )
        let entry = try #require(index.entry(
            workspaceId: fixture.key.workspaceId,
            panelId: fixture.key.panelId
        ))
        let evidence = AgentHibernationLiveProcessEvidence.resolve(
            observation: entry,
            agent: entry.snapshot
        )

        #expect(entry.hasHookRestoreAuthority)
        #expect(Set(entry.processIdentities.keys) != entry.processIDs)
        #expect(evidence.ownership == .unverified)
        #expect(!evidence.allowsHibernation)
    }

    @Test
    func terminationSignalsOnlyValidatedProcessIDs() {
        let childPID = pid_t(pid + 1)
        var signaled: [(pid_t, Int32)] = []

        AgentHibernationController.signalValidatedProcessIDsForHibernation(
            [pid_t(pid), childPID],
            signal: { target, signal in
                signaled.append((target, signal))
                return 0
            }
        )

        #expect(signaled.map(\.0) == [pid_t(pid), childPID])
        #expect(signaled.allSatisfy { $0.0 > 0 && $0.1 == SIGTERM })
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

    private struct HookFixture {
        let home: URL
        let key: RestorableAgentSessionIndex.PanelKey
        let sessionId: String
    }

    private func hookFixture(
        sessionId: String,
        pid: Int? = nil,
        updatedAt: TimeInterval = 100
    ) throws -> HookFixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-owned-live-authority-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: UUID(), panelId: UUID())
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": key.workspaceId.uuidString,
            "surfaceId": key.panelId.uuidString,
            "cwd": "/tmp/cmux-owned-live",
            "agentLifecycle": "idle",
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "opencode",
                "executablePath": "/usr/local/bin/opencode",
                "arguments": ["/usr/local/bin/opencode"],
                "workingDirectory": "/tmp/cmux-owned-live",
            ],
        ]
        if let pid { record["pid"] = pid }
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": [sessionId: record]],
            options: [.prettyPrinted]
        )
        try data.write(to: storeURL, options: .atomic)
        return HookFixture(home: home, key: key, sessionId: sessionId)
    }

    private func detected(
        fixture: HookFixture,
        sessionId: String,
        processIDs: Set<Int>,
        source: RestorableAgentSessionIndex.ProcessDetectedSessionIDSource
    ) -> [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry] {
        [
            fixture.key: (
                snapshot: SessionRestorableAgentSnapshot(
                    kind: .opencode,
                    sessionId: sessionId,
                    workingDirectory: "/tmp/cmux-owned-live",
                    launchCommand: AgentLaunchCommandSnapshot(
                        launcher: "opencode",
                        executablePath: "/usr/local/bin/opencode",
                        arguments: ["/usr/local/bin/opencode", "--session", sessionId],
                        workingDirectory: "/tmp/cmux-owned-live",
                        environment: nil,
                        capturedAt: nil,
                        source: nil
                    )
                ),
                updatedAt: 999,
                processIDs: processIDs,
                agentProcessIDs: [pid],
                sessionIDSource: source
            ),
        ]
    }

    private func loadIndex(
        fixture: HookFixture,
        detected: [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry] = [:],
        processArgumentsProvider: @escaping (Int) -> CmuxTopProcessArguments? = { _ in nil },
        processIdentityProvider: @escaping (Int) -> AgentPIDProcessIdentity?
    ) -> RestorableAgentSessionIndex {
        RestorableAgentSessionIndex.load(
            homeDirectory: fixture.home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detected,
            processArgumentsProvider: processArgumentsProvider,
            processIdentityProvider: processIdentityProvider
        )
    }

    private func scopedOpenCodeProcess(fixture: HookFixture) -> CmuxTopProcessArguments {
        CmuxTopProcessArguments(
            arguments: ["/usr/local/bin/opencode"],
            environment: [
                "CMUX_WORKSPACE_ID": fixture.key.workspaceId.uuidString,
                "CMUX_SURFACE_ID": fixture.key.panelId.uuidString,
                "CMUX_AGENT_LAUNCH_KIND": RestorableAgentKind.opencode.rawValue,
            ]
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
