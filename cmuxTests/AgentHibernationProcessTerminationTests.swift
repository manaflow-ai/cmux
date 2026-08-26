import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHibernationProcessTerminationTests {
    private nonisolated static let signalScopeKey = AgentHibernationPanelKey(
        workspaceId: UUID(),
        panelId: UUID()
    )
    private nonisolated static let signalScopeArguments = CmuxTopProcessArguments(
        arguments: ["/usr/bin/test-agent"],
        environment: [
            "CMUX_WORKSPACE_ID": signalScopeKey.workspaceId.uuidString,
            "CMUX_SURFACE_ID": signalScopeKey.panelId.uuidString,
        ]
    )

    private actor CompletionRecorder {
        private(set) var value: Bool?

        func record(_ value: Bool) {
            self.value = value
        }
    }

    @Test
    func processScopeRejectsPanelScopedSiblingOutsideAgentSubtree() {
        let workspaceID = UUID()
        let panelID = UUID()
        let ttyDevice = Int64(0x123)
        let process: (Int, Int, Bool) -> CmuxTopProcessInfo = {
            processID, parentProcessID, isEnvironmentScoped in
            CmuxTopProcessInfo(
                pid: processID, parentPID: parentProcessID, name: "test", path: nil,
                ttyDevice: ttyDevice,
                cmuxWorkspaceID: isEnvironmentScoped ? workspaceID : nil,
                cmuxSurfaceID: isEnvironmentScoped ? panelID : nil,
                cmuxAttributionReason: isEnvironmentScoped ? "environment" : nil,
                processGroupID: nil,
                terminalProcessGroupID: nil, cpuPercent: 0, residentBytes: 0,
                virtualBytes: 0, threadCount: 1
            )
        }
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(10, 1, true),
                process(20, 10, true),
                process(21, 20, false),
                process(30, 10, false),
            ],
            sampledAt: .now,
            includesProcessDetails: true
        )

        let scope = snapshot.agentHibernationProcessScope(
            panelProcessIDs: [10, 20],
            agentProcessIDs: [20]
        )

        #expect(scope.terminationProcessIDs == [20, 21])
        #expect(scope.containsUnrelatedProcess)
    }

    @Test
    func freshExitEpochProbesOnlyTTYAndAuthorizedGroupCandidates() async throws {
        let ttyDevice = Int64(0x123)
        let process: (Int, Int64, Int) -> CmuxTopProcessInfo = {
            processID, processTTYDevice, processGroupID in
            CmuxTopProcessInfo(
                pid: processID,
                parentPID: 1,
                name: "test",
                path: nil,
                ttyDevice: processTTYDevice,
                cmuxWorkspaceID: nil,
                cmuxSurfaceID: nil,
                cmuxAttributionReason: nil,
                processGroupID: processGroupID,
                terminalProcessGroupID: processGroupID,
                cpuPercent: 0,
                residentBytes: 0,
                virtualBytes: 0,
                threadCount: 1
            )
        }
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(101, ttyDevice, 101),
                process(202, ttyDevice, 202),
                process(303, 0x999, 303),
            ],
            sampledAt: .now,
            includesProcessDetails: false,
            includesCMUXScope: false
        )
        let rootIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let lateIdentity = AgentPIDProcessIdentity(
            pid: 202,
            startSeconds: 20,
            startMicroseconds: 2
        )
        let unrelatedIdentity = AgentPIDProcessIdentity(
            pid: 303,
            startSeconds: 30,
            startMicroseconds: 3
        )
        let identities = [
            pid_t(101): rootIdentity,
            pid_t(202): lateIdentity,
            pid_t(303): unrelatedIdentity,
        ]
        let probedProcessIDs = OSAllocatedUnfairLock(initialState: Set<Int>())
        let coordinator = AgentHibernationProcessSnapshotCoordinator(
            captureSnapshot: { snapshot },
            processArgumentsProvider: { processID in
                probedProcessIDs.withLock { $0.insert(processID) }
                return Self.signalScopeArguments
            },
            processIdentityProvider: { identities[$0] },
            processGroupProvider: { $0 }
        )

        let epoch = try #require(
            await coordinator.refreshedExitEpoch(
                processGroupLeaders: [101: rootIdentity],
                processScopeKey: Self.signalScopeKey,
                ttyDevice: ttyDevice,
                excluding: []
            )
        )

        #expect(Set(epoch.terminations.map(\.processID)) == [101, 202])
        #expect(epoch.signalableProcessIdentities == [rootIdentity])
        #expect(probedProcessIDs.withLock { $0 } == [101, 202])
    }

    @MainActor
    @Test
    func terminationSignalsValidatedProcessGroupWithoutRedundantPIDSignal() async {
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let signaledTargets = OSAllocatedUnfairLock(initialState: [pid_t]())

        let result = await AgentHibernationController
            .terminateScopedProcessesForHibernation(
                [
                    .init(
                        processID: 101,
                        processIdentity: identity,
                        processGroupID: 101,
                        ttyDevice: 123
                    ),
                ],
                processScopeKey: Self.signalScopeKey,
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { _ in identity },
                processGroupProvider: { _ in 101 },
                processArgumentsProvider: { _ in Self.signalScopeArguments },
                processTTYDeviceProvider: { _ in 123 },
                signalErrorProvider: { target, _ in
                    signaledTargets.withLock { $0.append(target) }
                    return nil
                }
            )

        #expect(result == .committedAwaitingExit)
        #expect(signaledTargets.withLock { $0 } == [-101])

        let allowExit = AsyncStream<Void>.makeStream()
        let escalatedTargets = OSAllocatedUnfairLock(initialState: [pid_t]())
        let deadlineCallCount = OSAllocatedUnfairLock(initialState: 0)
        let postKillDeadline = AsyncStream<Void>.makeStream()
        let lateIdentity = AgentPIDProcessIdentity(
            pid: 202,
            startSeconds: 20,
            startMicroseconds: 2
        )
        let didExit = await AgentHibernationController
            .waitForScopedProcessGenerationsToExitAfterEscalation(
                [.init(processID: 101, processIdentity: identity, processGroupID: 101)],
                waitForExit: { _ in
                    for await _ in allowExit.stream { return true }
                    return false
                },
                sleepUntilDeadline: { _ in
                    let call = deadlineCallCount.withLock {
                        $0 += 1
                        return $0
                    }
                    guard call > 1 else { return true }
                    for await _ in postKillDeadline.stream { return true }
                    return false
                },
                processIdentityProvider: { processID in
                    switch processID {
                    case 101: identity
                    case 202: lateIdentity
                    default: nil
                    }
                },
                processGroupProvider: { $0 },
                signalErrorProvider: { target, signal in
                    escalatedTargets.withLock { $0.append(target) }
                    #expect(signal == SIGKILL)
                    allowExit.continuation.yield()
                    allowExit.continuation.finish()
                    return nil
                },
                nextEpochProvider: { processGroupLeaders, _, _, _ in
                    AgentHibernationProcessExitEpoch(
                        terminations: [
                            .init(
                                processID: 101,
                                processIdentity: identity,
                                processGroupID: 101
                            ),
                            .init(
                                processID: 202,
                                processIdentity: lateIdentity,
                                processGroupID: 202
                            ),
                        ],
                        processGroupLeaders: processGroupLeaders,
                        signalableProcessIdentities: [identity]
                    )
                }
            )
        #expect(didExit)
        #expect(escalatedTargets.withLock { $0 } == [-101])
        postKillDeadline.continuation.finish()
    }

    @MainActor
    @Test
    func mutableCommitGateRunsAfterBlockingProcessProbes() async {
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let didProbe = OSAllocatedUnfairLock(initialState: false)
        let signaledTargets = OSAllocatedUnfairLock(initialState: [pid_t]())

        let result = await AgentHibernationController
            .terminateScopedProcessesForHibernation(
                [
                    .init(
                        processID: 101,
                        processIdentity: identity,
                        processGroupID: 101,
                        ttyDevice: 123
                    ),
                ],
                processScopeKey: Self.signalScopeKey,
                shouldCommit: {
                    #expect(didProbe.withLock { $0 })
                    return false
                },
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { _ in identity },
                processGroupProvider: { _ in 101 },
                processArgumentsProvider: { _ in
                    didProbe.withLock { $0 = true }
                    return Self.signalScopeArguments
                },
                processTTYDeviceProvider: { _ in 123 },
                signalErrorProvider: { target, _ in
                    signaledTargets.withLock { $0.append(target) }
                    return nil
                }
            )

        #expect(result == .rejected)
        #expect(signaledTargets.withLock { $0 }.isEmpty)
    }

    @Test
    func sigkillEscalationRejectsFreshScopeDrift() async {
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let termination = AgentHibernationController.ScopedProcessTermination(
            processID: 101,
            processIdentity: identity,
            processGroupID: 101,
            ttyDevice: 123
        )
        let exitWait = AsyncStream<Void>.makeStream()
        let signaledTargets = OSAllocatedUnfairLock(initialState: [pid_t]())
        let wrongScopeArguments = CmuxTopProcessArguments(
            arguments: ["/usr/bin/test-agent"],
            environment: [
                "CMUX_WORKSPACE_ID": UUID().uuidString,
                "CMUX_SURFACE_ID": UUID().uuidString,
            ]
        )

        let didExit = await AgentHibernationController
            .waitForScopedProcessGenerationsToExitAfterEscalation(
                [termination],
                processScopeKey: Self.signalScopeKey,
                gracePeriod: .zero,
                postKillExitPeriod: .zero,
                waitForExit: { _ in
                    for await _ in exitWait.stream {}
                    return false
                },
                sleepUntilDeadline: { _ in true },
                processIdentityProvider: { _ in identity },
                processGroupProvider: { _ in 101 },
                processArgumentsProvider: { _ in wrongScopeArguments },
                processTTYDeviceProvider: { _ in 123 },
                signalErrorProvider: { target, _ in
                    signaledTargets.withLock { $0.append(target) }
                    return nil
                },
                nextEpochProvider: { processGroupLeaders, _, _, _ in
                    AgentHibernationProcessExitEpoch(
                        terminations: [termination],
                        processGroupLeaders: processGroupLeaders,
                        signalableProcessIdentities: [identity]
                    )
                }
            )

        #expect(didExit == false)
        #expect(signaledTargets.withLock { $0 }.isEmpty)
        exitWait.continuation.finish()
    }

    @MainActor
    @Test
    func signalBatchFinishesBeforeCommittedUITransition() async {
        let firstIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let secondIdentity = AgentPIDProcessIdentity(
            pid: 202,
            startSeconds: 20,
            startMicroseconds: 2
        )
        let events = OSAllocatedUnfairLock(initialState: [String]())

        let result = await AgentHibernationController
            .terminateScopedProcessesForHibernation(
                [
                    .init(
                        processID: 101,
                        processIdentity: firstIdentity,
                        processGroupID: 101,
                        ttyDevice: 123
                    ),
                    .init(
                        processID: 202,
                        processIdentity: secondIdentity,
                        processGroupID: 202,
                        ttyDevice: 123
                    ),
                ],
                processScopeKey: Self.signalScopeKey,
                onTeardownCommit: {
                    events.withLock { $0.append("commit") }
                },
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { pid in
                    pid == 101 ? firstIdentity : secondIdentity
                },
                processGroupProvider: { $0 },
                processArgumentsProvider: { _ in Self.signalScopeArguments },
                processTTYDeviceProvider: { _ in 123 },
                signalErrorProvider: { target, _ in
                    events.withLock { $0.append("signal:\(target)") }
                    return nil
                }
            )

        #expect(result == .committedAwaitingExit)
        #expect(events.withLock { $0 } == ["signal:-101", "signal:-202", "commit"])
    }

    @Test
    func processScopeIncludesRelatedWrapperGroupLeader() {
        let workspaceID = UUID()
        let panelID = UUID()
        let ttyDevice = Int64(0x123)
        let process: (Int, Int, Int) -> CmuxTopProcessInfo = {
            processID, parentProcessID, processGroupID in
            CmuxTopProcessInfo(
                pid: processID, parentPID: parentProcessID, name: "test", path: nil,
                ttyDevice: ttyDevice,
                cmuxWorkspaceID: workspaceID,
                cmuxSurfaceID: panelID,
                cmuxAttributionReason: "environment",
                processGroupID: processGroupID,
                terminalProcessGroupID: processGroupID, cpuPercent: 0, residentBytes: 0,
                virtualBytes: 0, threadCount: 1
            )
        }
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(100, 1, 100),
                process(101, 100, 100),
                process(102, 101, 100),
            ],
            sampledAt: .now,
            includesProcessDetails: true
        )

        let scope = snapshot.agentHibernationProcessScope(
            panelProcessIDs: [100, 101, 102],
            agentProcessIDs: [101]
        )

        #expect(scope.terminationProcessIDs == [100, 101, 102])
        #expect(scope.containsUnrelatedProcess == false)
    }

    @Test
    func processScopeRejectsDescendantWithoutSharedTTYEvidence() {
        let workspaceID = UUID()
        let panelID = UUID()
        let ttyDevice = Int64(0x123)
        let process: (Int, Int, Int64?, Bool) -> CmuxTopProcessInfo = {
            processID, parentProcessID, processTTYDevice, isAgentProcess in
            CmuxTopProcessInfo(
                pid: processID,
                parentPID: parentProcessID,
                name: "test-\(processID)",
                path: "/usr/bin/test-\(processID)",
                ttyDevice: processTTYDevice,
                cmuxWorkspaceID: isAgentProcess ? workspaceID : nil,
                cmuxSurfaceID: isAgentProcess ? panelID : nil,
                cmuxAttributionReason: isAgentProcess ? "cmux-test" : nil,
                processGroupID: 100,
                terminalProcessGroupID: 100,
                cpuPercent: 0,
                residentBytes: 0,
                virtualBytes: 0,
                threadCount: 1
            )
        }
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(100, 1, ttyDevice, false),
                process(101, 100, ttyDevice, true),
                process(102, 101, nil, false),
            ],
            sampledAt: .now,
            includesProcessDetails: true
        )

        let scope = snapshot.agentHibernationProcessScope(
            panelProcessIDs: [101, 102],
            agentProcessIDs: [101]
        )

        #expect(scope.terminationProcessIDs == [100, 101, 102])
        #expect(scope.containsUnrelatedProcess)
    }

    @Test
    func validatesExactProcessGeneration() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let firstIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let secondIdentity = AgentPIDProcessIdentity(
            pid: 202,
            startSeconds: 20,
            startMicroseconds: 2
        )
        let identities = [101: firstIdentity, 202: secondIdentity]
        let scope = AgentHibernationController.ProcessTerminationScope(
            key: AgentHibernationPanelKey(workspaceId: workspaceID, panelId: panelID),
            processIDs: Set(identities.keys),
            processIdentities: identities
        )

        let terminations = try #require(
            AgentHibernationController.validatedScopedProcessTerminations(
                for: scope,
                processIdentityProvider: { identities[$0] },
                processGroupProvider: { pid_t($0 + 1_000) }
            )
        )

        #expect(
            terminations == [
                .init(
                    processID: 202,
                    processIdentity: secondIdentity,
                    processGroupID: 1_202
                ),
                .init(
                    processID: 101,
                    processIdentity: firstIdentity,
                    processGroupID: 1_101
                ),
            ]
        )
    }

    @Test
    func rejectsReusedProcessIdentity() {
        let workspaceID = UUID()
        let panelID = UUID()
        let capturedIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let scope = AgentHibernationController.ProcessTerminationScope(
            key: AgentHibernationPanelKey(workspaceId: workspaceID, panelId: panelID),
            processIDs: [101],
            processIdentities: [101: capturedIdentity]
        )

        let terminations = AgentHibernationController.validatedScopedProcessTerminations(
            for: scope,
            processIdentityProvider: { _ in
                AgentPIDProcessIdentity(
                    pid: 101,
                    startSeconds: 11,
                    startMicroseconds: 0
                )
            },
            processGroupProvider: { _ in 1_101 }
        )

        #expect(terminations == nil)
    }

    @Test
    func rejectsScopeWithUnrecordedProcessIdentity() {
        let workspaceID = UUID()
        let panelID = UUID()
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let scope = AgentHibernationController.ProcessTerminationScope(
            key: AgentHibernationPanelKey(workspaceId: workspaceID, panelId: panelID),
            processIDs: [101, 202],
            processIdentities: [101: identity]
        )

        let terminations = AgentHibernationController.validatedScopedProcessTerminations(
            for: scope,
            processIdentityProvider: { _ in identity },
            processGroupProvider: { _ in 1_101 }
        )

        #expect(terminations == nil)
    }

    @MainActor
    @Test
    func committedObservationDoesNotCompleteUntilTheExactProcessGenerationExits() async {
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let termination = AgentHibernationController.ScopedProcessTermination(
            processID: 101,
            processIdentity: identity,
            processGroupID: 101,
            ttyDevice: 123
        )
        let waitStarted = AsyncStream<Void>.makeStream()
        let allowExit = AsyncStream<Void>.makeStream()
        let controller = AgentHibernationController.shared
        let panelID = UUID()
        var didComplete = false
        controller.observeCommittedTermination(
            panelID: panelID,
            terminations: [termination],
            waitForExit: { _ in
                waitStarted.continuation.yield()
                for await _ in allowExit.stream {
                    break
                }
                return true
            },
            onExit: {
                didComplete = true
                return true
            },
            onRecovery: {}
        )
        let task = controller.committedTerminationObservationsByPanelID[panelID]?.task
        var waitStartedIterator = waitStarted.stream.makeAsyncIterator()
        _ = await waitStartedIterator.next()

        #expect(!didComplete)

        allowExit.continuation.yield()
        allowExit.continuation.finish()
        await task?.value
        #expect(didComplete)
        waitStarted.continuation.finish()
    }

    @MainActor
    @Test
    func signalFailureOtherThanMissingProcessAbortsBeforeCommit() async {
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let termination = AgentHibernationController.ScopedProcessTermination(
            processID: 101,
            processIdentity: identity,
            processGroupID: 101
        )

        let result = await AgentHibernationController
            .terminateScopedProcessesForHibernation(
                [termination],
                processScopeKey: Self.signalScopeKey,
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { _ in identity },
                processGroupProvider: { _ in 101 },
                processArgumentsProvider: { _ in Self.signalScopeArguments },
                processTTYDeviceProvider: { _ in 123 },
                signalErrorProvider: { _, _ in EPERM }
            )

        #expect(result == .rejected)
    }

    @MainActor
    @Test
    func signalFailureAfterTeardownCommitStillWaitsForOriginalProcesses() async {
        let firstIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let secondIdentity = AgentPIDProcessIdentity(
            pid: 202,
            startSeconds: 20,
            startMicroseconds: 2
        )
        let terminations = [
            AgentHibernationController.ScopedProcessTermination(
                processID: 101,
                processIdentity: firstIdentity,
                processGroupID: 101,
                ttyDevice: 123
            ),
            AgentHibernationController.ScopedProcessTermination(
                processID: 202,
                processIdentity: secondIdentity,
                processGroupID: 202,
                ttyDevice: 123
            ),
        ]
        let waitRecorder = CompletionRecorder()

        let controller = AgentHibernationController.shared
        let result = await AgentHibernationController
            .terminateScopedProcessesForHibernation(
                terminations,
                processScopeKey: Self.signalScopeKey,
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { pid in
                    pid == 101 ? firstIdentity : secondIdentity
                },
                processGroupProvider: { pid in
                    pid
                },
                processArgumentsProvider: { _ in Self.signalScopeArguments },
                processTTYDeviceProvider: { _ in 123 },
                signalErrorProvider: { target, _ in
                    target == -101 || target == 101 ? nil : EPERM
                }
            )
        let panelID = UUID()
        controller.observeCommittedTermination(
            panelID: panelID,
            terminations: terminations,
            waitForExit: { observedTerminations in
                await waitRecorder.record(observedTerminations == terminations)
                return observedTerminations == terminations
            },
            onExit: { true },
            onRecovery: {}
        )
        let observationTask = controller
            .committedTerminationObservationsByPanelID[panelID]?
            .task
        await observationTask?.value
        #expect(await waitRecorder.value == true)
        #expect(result == .committedAwaitingExit)
    }

    @MainActor
    @Test
    func resumeStaysUnavailableUntilCommittedTerminationCompletes() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.close() }
        let agent = SessionRestorableAgentSnapshot(
            kind: .custom("test-agent"),
            sessionId: "committed-hibernation",
            workingDirectory: "/tmp",
            launchCommand: nil
        )

        panel.beginAgentHibernationTermination(
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )

        #expect(panel.isAgentHibernated)
        #expect(panel.isAgentHibernationTerminating)
        #expect(panel.prepareAgentHibernationResume() == .unavailable)

        panel.completeAgentHibernationTermination()

        #expect(!panel.isAgentHibernationTerminating)
        #expect(panel.prepareAgentHibernationResume() == .resumed(queuedStartupInput: false))
        #expect(!panel.isAgentHibernated)
    }

    @MainActor
    @Test
    func exitDeadlineDoesNotBlockLaterWorkWhileCommittedPanelAwaitsExit() async {
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let termination = AgentHibernationController.ScopedProcessTermination(
            processID: 101,
            processIdentity: identity,
            processGroupID: 101,
            ttyDevice: 123
        )
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.close() }
        let agent = SessionRestorableAgentSnapshot(
            kind: .custom("test-agent"),
            sessionId: "eventual-exit-hibernation",
            workingDirectory: "/tmp",
            launchCommand: nil
        )
        let eventualWaitStarted = AsyncStream<Void>.makeStream()
        let allowEventualExit = AsyncStream<Void>.makeStream()
        let controller = AgentHibernationController.shared
        let result = await AgentHibernationController.terminateScopedProcessesForHibernation(
            [termination],
            processScopeKey: Self.signalScopeKey,
            onTeardownCommit: { [weak panel] in
                panel?.beginAgentHibernationTermination(
                    agent: agent,
                    lastActivityAt: Date(timeIntervalSince1970: 1)
                )
            },
            currentProcessID: 999,
            currentProcessGroupID: 999,
            processIdentityProvider: { _ in identity },
            processGroupProvider: { _ in 101 },
            processArgumentsProvider: { _ in Self.signalScopeArguments },
            processTTYDeviceProvider: { _ in 123 },
            signalErrorProvider: { _, _ in nil }
        )
        #expect(result == .committedAwaitingExit)
        controller.observeCommittedTermination(
            panelID: panel.id,
            terminations: [termination],
            waitForExit: { _ in
                eventualWaitStarted.continuation.yield()
                for await _ in allowEventualExit.stream {
                    break
                }
                return true
            },
            onExit: {
                panel.completeAgentHibernationTermination()
                return true
            },
            onRecovery: {
                panel.completeAgentHibernationTermination()
            }
        )
        let observationTask = controller
            .committedTerminationObservationsByPanelID[panel.id]?
            .task
        var eventualWaitStartedIterator = eventualWaitStarted.stream.makeAsyncIterator()
        _ = await eventualWaitStartedIterator.next()

        #expect(panel.isAgentHibernationTerminating)
        #expect(panel.prepareAgentHibernationResume() == .unavailable)

        allowEventualExit.continuation.yield()
        allowEventualExit.continuation.finish()
        await observationTask?.value

        #expect(!panel.isAgentHibernationTerminating)
        #expect(panel.isAgentHibernated)
        eventualWaitStarted.continuation.finish()
    }

    @Test
    func aReusedPIDMeansTheOriginalProcessGenerationExited() async {
        let originalIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let reusedIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 11,
            startMicroseconds: 0
        )

        let didExit = await AgentHibernationController
            .waitForExactProcessGenerationsToExitWithoutTimeout(
            [
                .init(
                    processID: 101,
                    processIdentity: originalIdentity,
                    processGroupID: 1
                ),
            ],
            processIdentityProvider: { _ in reusedIdentity }
        )

        #expect(didExit)
    }

    @Test
    func scopedExitWaitIncludesLateProcessInAuthorizedGroup() async {
        let processScopeKey = AgentHibernationPanelKey(
            workspaceId: UUID(),
            panelId: UUID()
        )
        let rootIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let lateIdentity = AgentPIDProcessIdentity(
            pid: 202,
            startSeconds: 20,
            startMicroseconds: 2
        )
        let nextEpochCount = OSAllocatedUnfairLock(initialState: 0)
        let waitCompleted = OSAllocatedUnfairLock(initialState: false)
        let lateEpochStarted = AsyncStream<Void>.makeStream()
        let allowLateExit = AsyncStream<Void>.makeStream()
        let wait = Task {
            let didExit = await AgentHibernationController
                .waitForScopedProcessGenerationsToExitWithoutTimeout(
                    [
                        .init(
                            processID: 101,
                            processIdentity: rootIdentity,
                            processGroupID: 101,
                            ttyDevice: 123
                        ),
                    ],
                    processScopeKey: processScopeKey,
                    waitForExactEpoch: { epoch in
                        guard epoch.contains(where: {
                            $0.processIdentity == lateIdentity
                        }) else {
                            return true
                        }
                        lateEpochStarted.continuation.yield()
                        for await _ in allowLateExit.stream { return true }
                        return false
                    },
                    nextEpochProvider: {
                        processGroupLeaders,
                        receivedScopeKey,
                        receivedTTYDevice,
                        exitedIdentities in
                        #expect(receivedScopeKey == processScopeKey)
                        #expect(receivedTTYDevice == 123)
                        let call = nextEpochCount.withLock {
                            $0 += 1
                            return $0
                        }
                        guard call == 1 else {
                            #expect(processGroupLeaders[101] == rootIdentity)
                            #expect(exitedIdentities == [rootIdentity, lateIdentity])
                            return AgentHibernationProcessExitEpoch(
                                terminations: [],
                                processGroupLeaders: [:]
                            )
                        }
                        #expect(exitedIdentities == [rootIdentity])
                        return AgentHibernationProcessExitEpoch(
                            terminations: [
                                .init(
                                    processID: 202,
                                    processIdentity: lateIdentity,
                                    processGroupID: 101
                                ),
                            ],
                            processGroupLeaders: [101: rootIdentity]
                        )
                    }
                )
            waitCompleted.withLock { $0 = true }
            return didExit
        }
        var lateEpochIterator = lateEpochStarted.stream.makeAsyncIterator()
        _ = await lateEpochIterator.next()

        #expect(waitCompleted.withLock { $0 } == false)

        allowLateExit.continuation.yield()
        allowLateExit.continuation.finish()
        #expect(await wait.value)
        lateEpochStarted.continuation.finish()
    }

    @Test
    func scopedExitWaitObservesLateProcessWithoutAuthorizingItsGroup() async {
        let rootIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let lateIdentity = AgentPIDProcessIdentity(
            pid: 202,
            startSeconds: 20,
            startMicroseconds: 2
        )

        let refreshCount = OSAllocatedUnfairLock(initialState: 0)
        let didExit = await AgentHibernationController
            .waitForScopedProcessGenerationsToExitWithoutTimeout(
                [
                    .init(
                        processID: 101,
                        processIdentity: rootIdentity,
                        processGroupID: 101
                    ),
                ],
                waitForExactEpoch: { _ in true },
                nextEpochProvider: { processGroupLeaders, _, _, _ in
                    let refresh = refreshCount.withLock {
                        $0 += 1
                        return $0
                    }
                    guard refresh == 1 else {
                        return AgentHibernationProcessExitEpoch(
                            terminations: [],
                            processGroupLeaders: processGroupLeaders
                        )
                    }
                    return AgentHibernationProcessExitEpoch(
                        terminations: [
                            .init(
                                processID: 202,
                                processIdentity: lateIdentity,
                                processGroupID: 202
                            ),
                        ],
                        processGroupLeaders: processGroupLeaders
                    )
                }
            )

        #expect(didExit)
    }
}
