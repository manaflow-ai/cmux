import CmuxFoundation
import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentHibernationProcessSignalBoundaryTests {
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

    @MainActor
    @Test
    func rejectsScopeOrTTYDriftWithoutSendingSignals() async {
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
        let signaledTargets = OSAllocatedUnfairLock(initialState: [pid_t]())
        let wrongScopeArguments = CmuxTopProcessArguments(
            arguments: ["/usr/bin/test-agent"],
            environment: [
                "CMUX_WORKSPACE_ID": UUID().uuidString,
                "CMUX_SURFACE_ID": UUID().uuidString,
            ]
        )

        let wrongScopeResult = await AgentHibernationController
            .terminateScopedProcessesForHibernation(
                [
                    .init(
                        processID: 101,
                        processIdentity: firstIdentity,
                        processGroupID: 101,
                        ttyDevice: 123
                    ),
                ],
                processScopeKey: Self.signalScopeKey,
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { _ in firstIdentity },
                processGroupProvider: { _ in 101 },
                processArgumentsProvider: { _ in wrongScopeArguments },
                processTTYDeviceProvider: { _ in 123 },
                signalErrorProvider: { target, _ in
                    signaledTargets.withLock { $0.append(target) }
                    return nil
                }
            )
        let ttyDriftResult = await AgentHibernationController
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
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { pid in
                    pid == 101 ? firstIdentity : secondIdentity
                },
                processGroupProvider: { $0 },
                processArgumentsProvider: { _ in Self.signalScopeArguments },
                processTTYDeviceProvider: { pid in
                    pid == 101 ? 123 : 456
                },
                signalErrorProvider: { target, _ in
                    signaledTargets.withLock { $0.append(target) }
                    return nil
                }
            )

        #expect(wrongScopeResult == .rejected)
        #expect(ttyDriftResult == .rejected)
        #expect(signaledTargets.withLock { $0 }.isEmpty)
    }

    private nonisolated static let agentIdentity = AgentPIDProcessIdentity(
        pid: 101,
        startSeconds: 10,
        startMicroseconds: 1
    )
    private nonisolated static let helperIdentity = AgentPIDProcessIdentity(
        pid: 202,
        startSeconds: 20,
        startMicroseconds: 2
    )
    /// `cmux hooks claude inbox-wait`, detached by Claude Code into its own
    /// process group with no terminal.
    private nonisolated static let helperArguments = CmuxTopProcessArguments(
        arguments: ["/Applications/cmux.app/Contents/Resources/bin/cmux", "hooks", "claude", "inbox-wait"],
        environment: signalScopeArguments.environment
    )
    private nonisolated static let agentAndHelperTerminations: [AgentHibernationController.ScopedProcessTermination] = [
        .init(processID: 101, processIdentity: agentIdentity, processGroupID: 101, ttyDevice: 123),
        .init(processID: 202, processIdentity: helperIdentity, processGroupID: 202, ttyDevice: nil, isCmuxHelper: true),
    ]

    /// Signals the agent's own group and the helper's, and nothing else.
    private func terminateAgentAndHelper(
        _ terminations: [AgentHibernationController.ScopedProcessTermination] =
            AgentHibernationProcessSignalBoundaryTests.agentAndHelperTerminations,
        helperArguments: CmuxTopProcessArguments =
            AgentHibernationProcessSignalBoundaryTests.helperArguments,
        helperTTYDevice: Int64? = nil,
        signaledTargets: OSAllocatedUnfairLock<[pid_t]>
    ) async -> AgentHibernationController.ScopedProcessTerminationResult {
        await AgentHibernationController.terminateScopedProcessesForHibernation(
            terminations,
            processScopeKey: Self.signalScopeKey,
            currentProcessID: 999,
            currentProcessGroupID: 999,
            processIdentityProvider: { $0 == 101 ? Self.agentIdentity : Self.helperIdentity },
            processGroupProvider: { $0 },
            processArgumentsProvider: { $0 == 101 ? Self.signalScopeArguments : helperArguments },
            processTTYDeviceProvider: { $0 == 101 ? 123 : helperTTYDevice },
            signalErrorProvider: { target, _ in
                signaledTargets.withLock { $0.append(target) }
                return nil
            }
        )
    }

    @MainActor
    @Test
    func signalsARegisteredHelperBesideItsAgent() async {
        let signaledTargets = OSAllocatedUnfairLock(initialState: [pid_t]())

        let result = await terminateAgentAndHelper(signaledTargets: signaledTargets)

        #expect(result == .committedAwaitingExit)
        #expect(signaledTargets.withLock { $0 } == [-101, -202])
        #expect(
            AgentHibernationController.commonTTYDevice(in: Self.agentAndHelperTerminations) == 123
        )
    }

    @MainActor
    @Test
    func rejectsAHelperWhoseOwnershipEvidenceChanged() async {
        let signaledTargets = OSAllocatedUnfairLock(initialState: [pid_t]())
        let otherCommand = CmuxTopProcessArguments(
            arguments: ["/usr/bin/python3", "-m", "http.server"],
            environment: Self.signalScopeArguments.environment
        )
        let otherSurface = CmuxTopProcessArguments(
            arguments: Self.helperArguments.arguments,
            environment: [
                "CMUX_WORKSPACE_ID": Self.signalScopeKey.workspaceId.uuidString,
                "CMUX_SURFACE_ID": UUID().uuidString,
            ]
        )
        // Detached work that was never scoped as a helper.
        let unregistered: [AgentHibernationController.ScopedProcessTermination] = [
            Self.agentAndHelperTerminations[0],
            .init(processID: 202, processIdentity: Self.helperIdentity, processGroupID: 202, ttyDevice: nil),
        ]

        let changedCommand = await terminateAgentAndHelper(
            helperArguments: otherCommand,
            signaledTargets: signaledTargets
        )
        let changedSurface = await terminateAgentAndHelper(
            helperArguments: otherSurface,
            signaledTargets: signaledTargets
        )
        let gainedTerminal = await terminateAgentAndHelper(
            helperTTYDevice: 123,
            signaledTargets: signaledTargets
        )
        let neverScoped = await terminateAgentAndHelper(
            unregistered,
            signaledTargets: signaledTargets
        )

        #expect(changedCommand == .rejected)
        #expect(changedSurface == .rejected)
        #expect(gainedTerminal == .rejected)
        #expect(neverScoped == .rejected)
        #expect(signaledTargets.withLock { $0 }.isEmpty)
    }

    @Test
    func helperScopeCarriesIntoValidatedTerminations() {
        let terminations = AgentHibernationController.validatedScopedProcessTerminations(
            for: .init(
                key: Self.signalScopeKey,
                processIDs: [101, 202],
                processIdentities: [101: Self.agentIdentity, 202: Self.helperIdentity],
                cmuxHelperProcessIDs: [202]
            ),
            processIdentityProvider: { $0 == 101 ? Self.agentIdentity : Self.helperIdentity },
            processGroupProvider: { pid_t($0) },
            processTTYDeviceProvider: { $0 == 101 ? 123 : nil }
        )

        #expect(terminations == Self.agentAndHelperTerminations.sorted { $0.processID > $1.processID })
    }

    @MainActor
    @Test
    func rejectsTTYChangeBeforeFinalCommit() async {
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let ttyProbeCount = OSAllocatedUnfairLock(initialState: 0)
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
                processTTYDeviceProvider: { _ in
                    let probe = ttyProbeCount.withLock {
                        $0 += 1
                        return $0
                    }
                    return probe == 1 ? 123 : 456
                },
                signalErrorProvider: { target, _ in
                    signaledTargets.withLock { $0.append(target) }
                    return nil
                }
            )

        #expect(result == .rejected)
        #expect(ttyProbeCount.withLock { $0 } == 2)
        #expect(signaledTargets.withLock { $0 }.isEmpty)
    }

    @MainActor
    @Test
    func rejectsMultipleRecordedTTYsBeforeSendingSignals() async {
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
        let didProbe = OSAllocatedUnfairLock(initialState: false)
        let signaledTargets = OSAllocatedUnfairLock(initialState: [pid_t]())

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
                        ttyDevice: 456
                    ),
                ],
                processScopeKey: Self.signalScopeKey,
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { _ in
                    didProbe.withLock { $0 = true }
                    return firstIdentity
                },
                signalErrorProvider: { target, _ in
                    signaledTargets.withLock { $0.append(target) }
                    return nil
                }
            )

        #expect(result == .rejected)
        #expect(didProbe.withLock { $0 } == false)
        #expect(signaledTargets.withLock { $0 }.isEmpty)
    }

    @MainActor
    @Test
    func rejectsUnboundedSignalAuthorityBeforeKernelProbes() async {
        let processCount =
            AgentHibernationController.maximumScopedProcessTerminationCount + 1
        let terminations = (1...processCount).map { offset in
            let processID = 100 + offset
            return AgentHibernationController.ScopedProcessTermination(
                processID: processID,
                processIdentity: .init(
                    pid: pid_t(processID),
                    startSeconds: Int64(processID),
                    startMicroseconds: 1
                ),
                processGroupID: pid_t(processID),
                ttyDevice: 123
            )
        }
        let didProbe = OSAllocatedUnfairLock(initialState: false)
        let signaledTargets = OSAllocatedUnfairLock(initialState: [pid_t]())

        let result = await AgentHibernationController
            .terminateScopedProcessesForHibernation(
                terminations,
                processScopeKey: Self.signalScopeKey,
                processIdentityProvider: { _ in
                    didProbe.withLock { $0 = true }
                    return nil
                },
                signalErrorProvider: { target, _ in
                    signaledTargets.withLock { $0.append(target) }
                    return nil
                }
            )

        #expect(result == .rejected)
        #expect(didProbe.withLock { $0 } == false)
        #expect(signaledTargets.withLock { $0 }.isEmpty)
    }

    @Test
    func rejectsUnboundedTerminationScopeBeforeKernelProbes() {
        let processCount =
            AgentHibernationController.maximumScopedProcessTerminationCount + 1
        let processIDs = Set(1...processCount)
        let identities = Dictionary(
            uniqueKeysWithValues: processIDs.map { processID in
                (
                    processID,
                    AgentPIDProcessIdentity(
                        pid: pid_t(processID),
                        startSeconds: Int64(processID),
                        startMicroseconds: 1
                    )
                )
            }
        )
        let didProbe = OSAllocatedUnfairLock(initialState: false)

        let terminations = AgentHibernationController
            .validatedScopedProcessTerminations(
                for: .init(
                    key: Self.signalScopeKey,
                    processIDs: processIDs,
                    processIdentities: identities
                ),
                processIdentityProvider: { _ in
                    didProbe.withLock { $0 = true }
                    return nil
                },
                processGroupProvider: { _ in
                    didProbe.withLock { $0 = true }
                    return 0
                }
            )

        #expect(terminations == nil)
        #expect(didProbe.withLock { $0 } == false)
    }

    @Test
    func boundsLateGenerationRefreshChurn() async {
        let rootIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let refreshCount = OSAllocatedUnfairLock(initialState: 0)
        let waitedEpochCount = OSAllocatedUnfairLock(initialState: 0)

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
                processScopeKey: Self.signalScopeKey,
                waitForExactEpoch: { _ in
                    waitedEpochCount.withLock { $0 += 1 }
                    return true
                },
                nextEpochProvider: { processGroupLeaders, scopeKey, ttyDevice, _ in
                    #expect(scopeKey == Self.signalScopeKey)
                    #expect(ttyDevice == 123)
                    let refresh = refreshCount.withLock {
                        $0 += 1
                        return $0
                    }
                    let processID = 200 + refresh
                    return AgentHibernationProcessExitEpoch(
                        terminations: [
                            .init(
                                processID: processID,
                                processIdentity: .init(
                                    pid: pid_t(processID),
                                    startSeconds: Int64(processID),
                                    startMicroseconds: 1
                                ),
                                processGroupID: 101,
                                ttyDevice: 123
                            ),
                        ],
                        processGroupLeaders: processGroupLeaders
                    )
                }
            )

        #expect(didExit == false)
        #expect(
            refreshCount.withLock { $0 } ==
                AgentHibernationController.maximumProcessExitEpochRefreshCount
        )
        #expect(
            waitedEpochCount.withLock { $0 } ==
                AgentHibernationController.maximumProcessExitEpochRefreshCount + 1
        )
    }
}
