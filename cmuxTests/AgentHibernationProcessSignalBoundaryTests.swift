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
