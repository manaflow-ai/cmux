import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentHibernationOwnedLiveProcessTests {
    private let shellPID = 4_242
    private let ttyDevice: Int64 = 9_001

    @Test
    func processFreeShellProducesMinimalLease() throws {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let index = topologyIndex(
            key: key,
            identity: identity,
            ttyEnumeration: .complete([shellPID]),
            childEnumeration: .complete([])
        )

        let evidence = index.evidence(for: key)
        let lease = try #require(evidence.lease)
        #expect(evidence.allowsHibernation)
        #expect(evidence.processIDs.isEmpty)
        #expect(lease.workspaceId == key.workspaceId)
        #expect(lease.panelId == key.panelId)
        #expect(lease.shellPID == shellPID)
        #expect(lease.shellIdentity == identity)
        #expect(lease.ttyDevice == ttyDevice)
        #expect(lease.arguments == ["/bin/zsh", "-l"])
    }

    @Test
    func targetTTYOrChildUncertaintyFailsClosed() {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let cases: [(CmuxTopTargetedPIDEnumeration, CmuxTopTargetedPIDEnumeration)] = [
            (.incomplete, .complete([])),
            (.complete([shellPID, shellPID + 1]), .complete([])),
            (.complete([shellPID]), .incomplete),
            (.complete([shellPID]), .complete([shellPID + 1])),
        ]

        for (tty, children) in cases {
            let evidence = topologyIndex(
                key: key,
                identity: identity,
                ttyEnumeration: tty,
                childEnumeration: children
            ).evidence(for: key)
            #expect(!evidence.allowsHibernation)
            #expect(evidence.lease == nil)
        }
    }

    @Test
    func unrelatedUnreadableProcessDoesNotPoisonTargetedProof() {
        let key = panelKey()
        let otherKey = panelKey()
        let identity = processIdentity(pid: shellPID)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                shellProcess(key: key, identity: identity),
                shellProcess(
                    key: otherKey,
                    pid: shellPID + 100,
                    ttyDevice: ttyDevice + 100,
                    identity: nil
                ),
            ],
            sampledAt: Date(),
            includesProcessDetails: true
        )
        let index = AgentHibernationProcessTopologyIndex(
            processSnapshot: snapshot,
            targetPanelKeys: [key],
            processArguments: { pid in pid == self.shellPID ? self.shellArguments(key: key) : nil },
            processIdentity: { pid in pid == self.shellPID ? identity : nil },
            processExecutablePath: { pid in pid == self.shellPID ? "/bin/zsh" : nil },
            processSessionID: { pid in pid == self.shellPID ? pid_t(self.shellPID) : nil },
            ttyProcessIDs: { _ in .complete([self.shellPID]) },
            childProcessIDs: { _ in .complete([]) }
        )

        #expect(index.evidence(for: key).allowsHibernation)
    }

    @Test
    func topologyQueriesEachTargetTTYOnlyOnce() {
        let firstKey = panelKey()
        let secondKey = panelKey()
        let firstPID = shellPID
        let secondPID = shellPID + 1
        let firstIdentity = processIdentity(pid: firstPID)
        let secondIdentity = processIdentity(pid: secondPID)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                shellProcess(key: firstKey, pid: firstPID, identity: firstIdentity),
                shellProcess(key: secondKey, pid: secondPID, identity: secondIdentity),
            ],
            sampledAt: Date(),
            includesProcessDetails: true
        )
        var ttyQueries = 0
        _ = AgentHibernationProcessTopologyIndex(
            processSnapshot: snapshot,
            targetPanelKeys: [firstKey, secondKey],
            processArguments: { pid in
                pid == firstPID ? self.shellArguments(key: firstKey) : self.shellArguments(key: secondKey)
            },
            processIdentity: { pid in pid == firstPID ? firstIdentity : secondIdentity },
            processExecutablePath: { _ in "/bin/zsh" },
            processSessionID: { pid_t($0) },
            ttyProcessIDs: { _ in
                ttyQueries += 1
                return .complete([firstPID, secondPID])
            },
            childProcessIDs: { _ in .complete([]) }
        )

        #expect(ttyQueries == 1)
    }

    @Test
    func finalLeaseValidationRejectsEveryTopologyDrift() throws {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let lease = try #require(topologyIndex(
            key: key,
            identity: identity,
            ttyEnumeration: .complete([shellPID]),
            childEnumeration: .complete([])
        ).evidence(for: key).lease)
        let topology = AgentHibernationProcessFreeLease.ProcessTopology(
            parentPID: 1,
            name: "zsh",
            ttyDevice: ttyDevice,
            processGroupID: shellPID,
            terminalProcessGroupID: shellPID
        )
        func validates(
            arguments: [String] = ["/bin/zsh", "-l"],
            path: String = "/bin/zsh",
            ttyPIDs: Set<Int> = [shellPID],
            children: Set<Int> = [],
            currentIdentity: AgentPIDProcessIdentity? = identity,
            currentTopology: AgentHibernationProcessFreeLease.ProcessTopology? = topology
        ) -> Bool {
            lease.isStillProcessFree(
                processArguments: { _ in
                    CmuxTopProcessArguments(
                        arguments: arguments,
                        environment: [
                            "CMUX_WORKSPACE_ID": key.workspaceId.uuidString,
                            "CMUX_SURFACE_ID": key.panelId.uuidString,
                        ]
                    )
                },
                processIdentity: { _ in currentIdentity },
                processExecutablePath: { _ in path },
                processSessionID: { _ in pid_t(self.shellPID) },
                ttyProcessIDs: { _ in .complete(ttyPIDs) },
                childProcessIDs: { _ in .complete(children) },
                processTopology: { _ in currentTopology }
            )
        }

        #expect(validates())
        #expect(!validates(arguments: ["/usr/bin/read", "secret"]))
        #expect(!validates(path: "/bin/bash"))
        #expect(!validates(ttyPIDs: [shellPID, shellPID + 1]))
        #expect(!validates(children: [shellPID + 1]))
        #expect(!validates(currentIdentity: processIdentity(pid: shellPID, seconds: 101)))
        #expect(!validates(currentTopology: nil))
    }

    @Test
    func frozenLeaseClosesForkWindowUntilExplicitResume() throws {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let lease = try #require(topologyIndex(
            key: key,
            identity: identity,
            ttyEnumeration: .complete([shellPID]),
            childEnumeration: .complete([])
        ).evidence(for: key).lease)
        let state = AgentHibernationFrozenShellTestState(identity: identity, status: UInt32(SRUN))

        let frozen = try #require(lease.freezeForFinalTeardown(
            processIdentity: { _ in state.identity },
            processStatus: { _ in state.status },
            processGenerationFence: { _ in state.generationFence() },
            sendSignal: { _, signal in state.send(signal) },
            yieldThread: {},
            finalProcessFreeValidation: {
                state.recordFinalValidation()
                return state.status == UInt32(SSTOP) && !state.hasChild
            }
        ))

        #expect(state.finalValidationObservedStop)
        state.attemptFork()
        #expect(!state.hasChild)
        #expect(frozen.isStillFrozenAndProcessFree(finalProcessFreeValidation: {
            state.status == UInt32(SSTOP) && !state.hasChild
        }))
        frozen.resume()
        #expect(state.signals == [SIGSTOP, SIGCONT])
        state.attemptFork()
        #expect(state.hasChild)
    }

    @Test
    func frozenLeaseRejectsPreStoppedShellWithoutResumingIt() throws {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let lease = try #require(topologyIndex(
            key: key,
            identity: identity,
            ttyEnumeration: .complete([shellPID]),
            childEnumeration: .complete([])
        ).evidence(for: key).lease)
        let state = AgentHibernationFrozenShellTestState(identity: identity, status: UInt32(SSTOP))

        #expect(lease.freezeForFinalTeardown(
            processIdentity: { _ in state.identity },
            processStatus: { _ in state.status },
            processGenerationFence: { _ in state.generationFence() },
            sendSignal: { _, signal in state.send(signal) },
            yieldThread: {},
            finalProcessFreeValidation: { true }
        ) == nil)
        #expect(state.signals.isEmpty)
    }

    @Test
    func failedFrozenValidationResumesExactShellGeneration() throws {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let lease = try #require(topologyIndex(
            key: key,
            identity: identity,
            ttyEnumeration: .complete([shellPID]),
            childEnumeration: .complete([])
        ).evidence(for: key).lease)
        let state = AgentHibernationFrozenShellTestState(identity: identity, status: UInt32(SRUN))

        #expect(lease.freezeForFinalTeardown(
            processIdentity: { _ in state.identity },
            processStatus: { _ in state.status },
            processGenerationFence: { _ in state.generationFence() },
            sendSignal: { _, signal in state.send(signal) },
            yieldThread: {},
            finalProcessFreeValidation: { false }
        ) == nil)
        #expect(state.signals == [SIGSTOP, SIGCONT])
    }

    @Test
    func frozenLeaseUsesGenerationFenceWhenIdentityReadIsUnavailable() throws {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let lease = try #require(topologyIndex(
            key: key,
            identity: identity,
            ttyEnumeration: .complete([shellPID]),
            childEnumeration: .complete([])
        ).evidence(for: key).lease)
        let state = AgentHibernationFrozenShellTestState(identity: identity, status: UInt32(SRUN))
        let frozen = try #require(lease.freezeForFinalTeardown(
            processIdentity: { _ in state.readIdentity() },
            processStatus: { _ in state.status },
            processGenerationFence: { _ in state.generationFence() },
            sendSignal: { _, signal in state.send(signal) },
            yieldThread: {},
            finalProcessFreeValidation: { true }
        ))
        state.failNextIdentityReads(1)

        frozen.resume()
        #expect(state.status == UInt32(SRUN))
        #expect(state.signals == [SIGSTOP, SIGCONT])

        frozen.resume()
        #expect(state.signals == [SIGSTOP, SIGCONT])
    }

    @Test
    func frozenLeaseResumesThroughPersistentIdentityProbeFailure() throws {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let lease = try #require(topologyIndex(
            key: key,
            identity: identity,
            ttyEnumeration: .complete([shellPID]),
            childEnumeration: .complete([])
        ).evidence(for: key).lease)
        let state = AgentHibernationFrozenShellTestState(identity: identity, status: UInt32(SRUN))
        var frozen: AgentHibernationFrozenShellLease? = try #require(lease.freezeForFinalTeardown(
            processIdentity: { _ in state.readIdentity() },
            processStatus: { _ in state.status },
            processGenerationFence: { _ in state.generationFence() },
            sendSignal: { _, signal in state.send(signal) },
            yieldThread: {},
            finalProcessFreeValidation: { true }
        ))
        state.failNextIdentityReads(.max)

        frozen?.resume()
        frozen = nil

        #expect(state.status == UInt32(SRUN))
        #expect(state.signals == [SIGSTOP, SIGCONT])
    }

    @Test
    func frozenLeaseNeverSignalsAReplacementPIDGeneration() throws {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let lease = try #require(topologyIndex(
            key: key,
            identity: identity,
            ttyEnumeration: .complete([shellPID]),
            childEnumeration: .complete([])
        ).evidence(for: key).lease)
        let state = AgentHibernationFrozenShellTestState(identity: identity, status: UInt32(SRUN))
        let frozen = try #require(lease.freezeForFinalTeardown(
            processIdentity: { _ in state.identity },
            processStatus: { _ in state.status },
            processGenerationFence: { _ in state.generationFence() },
            sendSignal: { _, signal in state.send(signal) },
            yieldThread: {},
            finalProcessFreeValidation: { true }
        ))
        state.replaceIdentity(processIdentity(pid: shellPID, seconds: 101))

        frozen.resume()
        frozen.resume()
        #expect(state.signals == [SIGSTOP])
    }

    @MainActor
    @Test
    func frozenShellSpansFinalProcessProofDurableCommitAndNativeFree() async throws {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let lease = try #require(topologyIndex(
            key: key,
            identity: identity,
            ttyEnumeration: .complete([shellPID]),
            childEnumeration: .complete([])
        ).evidence(for: key).lease)
        let state = AgentHibernationFrozenShellTestState(identity: identity, status: UInt32(SRUN))
        let workspace = Workspace(workingDirectory: "/tmp")
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        panel.surface.installRuntimeSurfaceForTesting(runtimeSurface)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { pointer in
            state.recordNativeFree()
            pointer.deallocate()
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        let didHibernate = await panel.enterAgentHibernation(
            agent: restorableAgent(),
            lastActivityAt: Date(timeIntervalSince1970: 10),
            finalValidation: { true },
            finalTeardownPreparation: {
                guard let frozen = lease.freezeForFinalTeardown(
                    processIdentity: { _ in state.identity },
                    processStatus: { _ in state.status },
                    processGenerationFence: { _ in state.generationFence() },
                    sendSignal: { _, signal in state.send(signal) },
                    yieldThread: {},
                    finalProcessFreeValidation: {
                        state.recordFinalValidation()
                        return state.status == UInt32(SSTOP) && !state.hasChild
                    }
                ) else {
                    return nil
                }
                return { frozen.resume() }
            },
            finalCommit: {
                state.recordLifecycleCommit(accepted: true)
                return true
            }
        )

        #expect(didHibernate)
        #expect(panel.isAgentHibernated)
        #expect(state.events == [
            "SIGSTOP",
            "processFree",
            "lifecycleCommit",
            "nativeFree",
            "SIGCONT",
        ])
    }

    @MainActor
    @Test
    func rejectedDurableCommitResumesShellAndRestoresExactLiveRuntime() async throws {
        let key = panelKey()
        let identity = processIdentity(pid: shellPID)
        let lease = try #require(topologyIndex(
            key: key,
            identity: identity,
            ttyEnumeration: .complete([shellPID]),
            childEnumeration: .complete([])
        ).evidence(for: key).lease)
        let state = AgentHibernationFrozenShellTestState(identity: identity, status: UInt32(SRUN))
        let workspace = Workspace(workingDirectory: "/tmp")
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        panel.surface.installRuntimeSurfaceForTesting(runtimeSurface)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            state.recordNativeFree()
        }
        defer {
            if panel.surface.surface == runtimeSurface {
                panel.surface.runtimeSurfaceFreedOutOfBandForTesting = true
                panel.surface.teardownSurface()
                runtimeSurface.deallocate()
            }
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil
        }

        let didHibernate = await panel.enterAgentHibernation(
            agent: restorableAgent(),
            lastActivityAt: Date(timeIntervalSince1970: 10),
            finalValidation: { true },
            finalTeardownPreparation: {
                guard let frozen = lease.freezeForFinalTeardown(
                    processIdentity: { _ in state.identity },
                    processStatus: { _ in state.status },
                    processGenerationFence: { _ in state.generationFence() },
                    sendSignal: { _, signal in state.send(signal) },
                    yieldThread: {},
                    finalProcessFreeValidation: {
                        state.recordFinalValidation()
                        return state.status == UInt32(SSTOP) && !state.hasChild
                    }
                ) else {
                    return nil
                }
                return { frozen.resume() }
            },
            finalCommit: {
                state.recordLifecycleCommit(accepted: false)
                return false
            }
        )

        #expect(!didHibernate)
        #expect(!panel.isAgentHibernated)
        #expect(panel.surface.surface == runtimeSurface)
        #expect(state.events == [
            "SIGSTOP",
            "processFree",
            "lifecycleCommitRejected",
            "SIGCONT",
        ])
    }

    @Test
    func standardLoaderCannotAccidentallyAuthorizeHibernation() throws {
        let fixture = try hookFixture(sessionId: "standard-load")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let identity = processIdentity(pid: shellPID)
        let snapshot = processSnapshot(key: fixture.key, identity: identity)

        let standard = loadIndex(fixture: fixture, snapshot: snapshot, identity: identity, mode: .standard)
        let hibernation = loadIndex(
            fixture: fixture,
            snapshot: snapshot,
            identity: identity,
            mode: .hibernation(processSnapshot: snapshot)
        )

        #expect(!standard.processEvidence(
            workspaceId: fixture.key.workspaceId,
            panelId: fixture.key.panelId
        ).allowsHibernation)
        #expect(hibernation.processEvidence(
            workspaceId: fixture.key.workspaceId,
            panelId: fixture.key.panelId
        ).allowsHibernation)
    }

    @Test
    func staleLegacyPIDDoesNotPermanentlyPoisonProcessFreePanel() throws {
        let fixture = try hookFixture(sessionId: "legacy-stale-pid", recordedPID: 99_999)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let identity = processIdentity(pid: shellPID)
        let snapshot = processSnapshot(key: fixture.key, identity: identity)
        let index = loadIndex(
            fixture: fixture,
            snapshot: snapshot,
            identity: identity,
            mode: .hibernation(processSnapshot: snapshot)
        )

        #expect(index.processEvidence(
            workspaceId: fixture.key.workspaceId,
            panelId: fixture.key.panelId
        ).allowsHibernation)
    }

    @Test
    func restoredWorkspaceRekeyUsesExactLiveShellScope() throws {
        let fixture = try hookFixture(sessionId: "restored-workspace-rekey")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let liveKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: UUID(),
            panelId: fixture.key.panelId
        )
        let identity = processIdentity(pid: shellPID)
        let snapshot = processSnapshot(key: liveKey, identity: identity)
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: fixture.home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            mode: .hibernation(processSnapshot: snapshot),
            processArgumentsProvider: { pid in
                pid == self.shellPID ? self.shellArguments(key: liveKey) : nil
            },
            processIdentityProvider: { pid in pid == self.shellPID ? identity : nil },
            processExecutablePathProvider: { _ in "/bin/zsh" },
            processSessionIDProvider: { _ in pid_t(self.shellPID) },
            ttyProcessIDsProvider: { _ in .complete([self.shellPID]) },
            childProcessIDsProvider: { _ in .complete([]) }
        )

        #expect(index.entry(
            workspaceId: liveKey.workspaceId,
            panelId: liveKey.panelId
        )?.snapshot.sessionId == "restored-workspace-rekey")
        #expect(index.processEvidence(
            workspaceId: liveKey.workspaceId,
            panelId: liveKey.panelId
        ).allowsHibernation)
    }

    @Test
    func liveSameSurfaceInAnotherWorkspaceRevokesProcessFreeLease() throws {
        let fixture = try hookFixture(sessionId: "cross-runtime-live-owner")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let currentKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: UUID(),
            panelId: fixture.key.panelId
        )
        let identity = processIdentity(pid: shellPID)
        let otherAgentPID = shellPID + 500
        let otherAgentIdentity = processIdentity(pid: otherAgentPID)
        let snapshot = processSnapshot(key: currentKey, identity: identity)
        let detected: [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry] = [
            fixture.key: (
                snapshot: SessionRestorableAgentSnapshot(
                    kind: .opencode,
                    sessionId: "cross-runtime-live-owner",
                    workingDirectory: "/tmp/cmux-process-free",
                    launchCommand: nil
                ),
                updatedAt: 200,
                processIDs: [otherAgentPID],
                agentProcessIDs: [otherAgentPID],
                sessionIDSource: .explicit
            ),
        ]
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: fixture.home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detected,
            mode: .hibernation(processSnapshot: snapshot),
            processArgumentsProvider: { pid in
                pid == self.shellPID ? self.shellArguments(key: currentKey) : nil
            },
            processIdentityProvider: { pid in
                pid == self.shellPID ? identity : (pid == otherAgentPID ? otherAgentIdentity : nil)
            },
            processExecutablePathProvider: { _ in "/bin/zsh" },
            processSessionIDProvider: { _ in pid_t(self.shellPID) },
            ttyProcessIDsProvider: { _ in .complete([self.shellPID]) },
            childProcessIDsProvider: { _ in .complete([]) }
        )

        #expect(!index.processEvidence(
            workspaceId: currentKey.workspaceId,
            panelId: currentKey.panelId
        ).allowsHibernation)
        #expect(index.processEvidence(
            workspaceId: fixture.key.workspaceId,
            panelId: fixture.key.panelId
        ).processIDs == [otherAgentPID])
    }

    @Test
    func promptAndBothCloseGatesAreExact() {
        #expect(AgentHibernationController.passesPromptAndCloseGates(
            workspaceShellActivity: .promptIdle,
            panelShellActivity: .promptIdle,
            rawNeedsConfirmClose: false,
            workspaceNeedsConfirmClose: false
        ))
        #expect(!AgentHibernationController.passesPromptAndCloseGates(
            workspaceShellActivity: .unknown,
            panelShellActivity: .promptIdle,
            rawNeedsConfirmClose: false,
            workspaceNeedsConfirmClose: false
        ))
        #expect(!AgentHibernationController.passesPromptAndCloseGates(
            workspaceShellActivity: .promptIdle,
            panelShellActivity: .commandRunning,
            rawNeedsConfirmClose: false,
            workspaceNeedsConfirmClose: false
        ))
        #expect(!AgentHibernationController.passesPromptAndCloseGates(
            workspaceShellActivity: .promptIdle,
            panelShellActivity: .promptIdle,
            rawNeedsConfirmClose: true,
            workspaceNeedsConfirmClose: false
        ))
        #expect(!AgentHibernationController.passesPromptAndCloseGates(
            workspaceShellActivity: .promptIdle,
            panelShellActivity: .promptIdle,
            rawNeedsConfirmClose: false,
            workspaceNeedsConfirmClose: true
        ))
    }

    private struct HookFixture {
        let home: URL
        let key: RestorableAgentSessionIndex.PanelKey
    }

    private func panelKey() -> RestorableAgentSessionIndex.PanelKey {
        .init(workspaceId: UUID(), panelId: UUID())
    }

    private func processIdentity(pid: Int, seconds: Int64 = 100) -> AgentPIDProcessIdentity {
        AgentPIDProcessIdentity(pid: pid_t(pid), startSeconds: seconds, startMicroseconds: 0)
    }

    private func shellProcess(
        key: RestorableAgentSessionIndex.PanelKey,
        pid: Int? = nil,
        ttyDevice: Int64? = nil,
        identity: AgentPIDProcessIdentity?
    ) -> CmuxTopProcessInfo {
        let pid = pid ?? shellPID
        return CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: "zsh",
            path: "/bin/zsh",
            ttyDevice: ttyDevice ?? self.ttyDevice,
            cmuxWorkspaceID: key.workspaceId,
            cmuxSurfaceID: key.panelId,
            cmuxAttributionReason: "environment",
            processGroupID: pid,
            terminalProcessGroupID: pid,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1,
            generationIdentity: identity
        )
    }

    private func shellArguments(key: RestorableAgentSessionIndex.PanelKey) -> CmuxTopProcessArguments {
        CmuxTopProcessArguments(
            arguments: ["/bin/zsh", "-l"],
            environment: [
                "CMUX_WORKSPACE_ID": key.workspaceId.uuidString,
                "CMUX_SURFACE_ID": key.panelId.uuidString,
            ]
        )
    }

    private func processSnapshot(
        key: RestorableAgentSessionIndex.PanelKey,
        identity: AgentPIDProcessIdentity
    ) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: [shellProcess(key: key, identity: identity)],
            sampledAt: Date(),
            includesProcessDetails: true
        )
    }

    private func restorableAgent() -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "frozen-shell-integration",
            workingDirectory: "/tmp",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: "/tmp",
                environment: nil,
                capturedAt: 10,
                source: "test"
            )
        )
    }

    private func topologyIndex(
        key: RestorableAgentSessionIndex.PanelKey,
        identity: AgentPIDProcessIdentity,
        ttyEnumeration: CmuxTopTargetedPIDEnumeration,
        childEnumeration: CmuxTopTargetedPIDEnumeration
    ) -> AgentHibernationProcessTopologyIndex {
        AgentHibernationProcessTopologyIndex(
            processSnapshot: processSnapshot(key: key, identity: identity),
            targetPanelKeys: [key],
            processArguments: { _ in self.shellArguments(key: key) },
            processIdentity: { _ in identity },
            processExecutablePath: { _ in "/bin/zsh" },
            processSessionID: { _ in pid_t(self.shellPID) },
            ttyProcessIDs: { _ in ttyEnumeration },
            childProcessIDs: { _ in childEnumeration }
        )
    }

    private func hookFixture(sessionId: String, recordedPID: Int? = nil) throws -> HookFixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-process-free-lease-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let key = panelKey()
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": key.workspaceId.uuidString,
            "surfaceId": key.panelId.uuidString,
            "cwd": "/tmp/cmux-process-free",
            "agentLifecycle": "idle",
            "updatedAt": 100,
            "launchCommand": [
                "launcher": "opencode",
                "executablePath": "/usr/local/bin/opencode",
                "arguments": ["/usr/local/bin/opencode"],
                "workingDirectory": "/tmp/cmux-process-free",
            ],
        ]
        if let recordedPID { record["pid"] = recordedPID }
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": [sessionId: record]],
            options: [.prettyPrinted]
        )
        try data.write(to: storeURL, options: .atomic)
        return HookFixture(home: home, key: key)
    }

    private func loadIndex(
        fixture: HookFixture,
        snapshot: CmuxTopProcessSnapshot,
        identity: AgentPIDProcessIdentity,
        mode: RestorableAgentSessionIndex.LoadMode
    ) -> RestorableAgentSessionIndex {
        RestorableAgentSessionIndex.load(
            homeDirectory: fixture.home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            mode: mode,
            processArgumentsProvider: { pid in
                pid == self.shellPID ? self.shellArguments(key: fixture.key) : nil
            },
            processIdentityProvider: { pid in pid == self.shellPID ? identity : nil },
            processExecutablePathProvider: { pid in pid == self.shellPID ? "/bin/zsh" : nil },
            processSessionIDProvider: { pid in pid == self.shellPID ? pid_t(self.shellPID) : nil },
            ttyProcessIDsProvider: { _ in .complete([self.shellPID]) },
            childProcessIDsProvider: { _ in .complete([]) }
        )
    }
}

private final class AgentHibernationFrozenShellTestState: @unchecked Sendable {
    private struct Storage {
        var identity: AgentPIDProcessIdentity?
        var status: UInt32
        var signals: [Int32] = []
        var hasChild = false
        var finalValidationObservedStop = false
        var events: [String] = []
        var identityReadFailuresRemaining = 0
        var generationFenceState = AgentHibernationProcessGenerationFence.State
            .originalGenerationAlive
    }

    private let storage: OSAllocatedUnfairLock<Storage>

    init(identity: AgentPIDProcessIdentity, status: UInt32) {
        storage = OSAllocatedUnfairLock(initialState: Storage(identity: identity, status: status))
    }

    var identity: AgentPIDProcessIdentity? { storage.withLock { $0.identity } }
    var status: UInt32 { storage.withLock { $0.status } }
    var signals: [Int32] { storage.withLock { $0.signals } }
    var hasChild: Bool { storage.withLock { $0.hasChild } }
    var events: [String] { storage.withLock { $0.events } }
    var finalValidationObservedStop: Bool {
        storage.withLock { $0.finalValidationObservedStop }
    }

    func readIdentity() -> AgentPIDProcessIdentity? {
        storage.withLock { state in
            if state.identityReadFailuresRemaining > 0 {
                state.identityReadFailuresRemaining -= 1
                return nil
            }
            return state.identity
        }
    }

    func failNextIdentityReads(_ count: Int) {
        storage.withLock { $0.identityReadFailuresRemaining = max(0, count) }
    }

    func generationFence() -> AgentHibernationProcessGenerationFence {
        AgentHibernationProcessGenerationFence { [self] in
            storage.withLock { $0.generationFenceState }
        }
    }

    func replaceIdentity(_ identity: AgentPIDProcessIdentity?) {
        storage.withLock { $0.identity = identity }
    }

    func send(_ signal: Int32) -> Int32 {
        storage.withLock { state -> Int32 in
            state.signals.append(signal)
            if signal == SIGSTOP {
                state.status = UInt32(SSTOP)
                state.events.append("SIGSTOP")
            } else if signal == SIGCONT {
                state.status = UInt32(SRUN)
                state.events.append("SIGCONT")
            }
            return 0
        }
    }

    func attemptFork() {
        storage.withLock { state in
            if state.status != UInt32(SSTOP) {
                state.hasChild = true
            }
        }
    }

    func recordFinalValidation() {
        storage.withLock { state in
            state.finalValidationObservedStop = state.status == UInt32(SSTOP)
            state.events.append("processFree")
        }
    }

    func recordLifecycleCommit(accepted: Bool) {
        storage.withLock {
            $0.events.append(accepted ? "lifecycleCommit" : "lifecycleCommitRejected")
        }
    }

    func recordNativeFree() {
        storage.withLock { state in
            #expect(state.status == UInt32(SSTOP))
            state.events.append("nativeFree")
        }
    }
}
