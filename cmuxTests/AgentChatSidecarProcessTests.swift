import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentChatSidecarProcessTests {
    private let expected = AgentPIDProcessIdentity(
        pid: 4127,
        startSeconds: 100,
        startMicroseconds: 20
    )
    private let replacement = AgentPIDProcessIdentity(
        pid: 4127,
        startSeconds: 101,
        startMicroseconds: 20
    )

    @Test func stalePIDGenerationCannotProduceASignalTarget() {
        #expect(
            AgentChatSidecarProcessTerminator().validatedGroupTarget(
                identity: expected,
                processGroupID: 4127,
                currentIdentity: replacement,
                currentProcessGroupID: 4127
            ) == nil
        )
    }

    @Test func matchingGenerationProducesOnlyItsLaunchGroupTarget() {
        #expect(
            AgentChatSidecarProcessTerminator().validatedGroupTarget(
                identity: expected,
                processGroupID: 4127,
                currentIdentity: expected,
                currentProcessGroupID: 4127
            ) == -4127
        )
    }

    @Test func processTableRetainsTheGroupDuringIdentityReads() {
        #expect(AgentPIDProcessIdentity.processGroupID(pid: getpid()) == getpgrp())
    }

    @Test func terminationRefusesAReusedPIDWithoutSendingSignals() {
        var signals: [(pid_t, Int32)] = []
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { _ in replacement },
            processGroupProvider: { _ in 4127 },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return 0
            },
            sleepNanoseconds: { _ in }
        ).terminate(
            identities: [expected],
            processGroupID: 4127
        )

        #expect(!didTerminate)
        #expect(signals.isEmpty)
    }

    @Test func terminationRechecksIdentityBeforeEscalating() {
        var current: AgentPIDProcessIdentity? = expected
        var signals: [(pid_t, Int32)] = []
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { _ in current },
            processGroupProvider: { _ in 4127 },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                if signal == SIGTERM { current = nil }
                return 0
            },
            sleepNanoseconds: { _ in }
        ).terminate(
            identities: [expected],
            processGroupID: 4127
        )

        #expect(didTerminate)
        #expect(signals.count == 1)
        #expect(signals.first?.0 == -4127)
        #expect(signals.first?.1 == SIGTERM)
    }

    @Test func terminationFailsClosedWhenOneCapturedPIDWasReused() {
        let second = AgentPIDProcessIdentity(pid: 4128, startSeconds: 200, startMicroseconds: 0)
        var signals: [(pid_t, Int32)] = []
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { pid in pid == expected.pid ? expected : replacement },
            processGroupProvider: { _ in 4127 },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return 0
            },
            sleepNanoseconds: { _ in }
        ).terminate(
            identities: [expected, second],
            processGroupID: 4127
        )

        #expect(!didTerminate)
        #expect(signals.isEmpty)
    }

    @Test func terminationRevalidatesEveryCapturedPIDImmediatelyBeforeSignaling() {
        let first = expected
        let second = AgentPIDProcessIdentity(pid: 4128, startSeconds: 200, startMicroseconds: 0)
        let secondReplacement = AgentPIDProcessIdentity(pid: 4128, startSeconds: 201, startMicroseconds: 0)
        var secondReads = 0
        var signals: [(pid_t, Int32)] = []
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { pid in
                guard pid == second.pid else { return first }
                secondReads += 1
                return secondReads == 1 ? second : secondReplacement
            },
            processGroupProvider: { _ in 4127 },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return 0
            },
            sleepNanoseconds: { _ in }
        ).terminate(
            identities: [expected, second],
            processGroupID: 4127
        )

        #expect(!didTerminate)
        #expect(secondReads == 2)
        #expect(signals.isEmpty)
    }

    @Test func terminationReportsSignalFailureInsteadOfClaimingCleanup() {
        var signals: [(pid_t, Int32)] = []
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { _ in expected },
            processGroupProvider: { _ in 4127 },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return -1
            },
            sleepNanoseconds: { _ in }
        ).terminate(
            identities: [expected],
            processGroupID: 4127
        )

        #expect(!didTerminate)
        #expect(signals.count == 1)
        #expect(signals.first?.0 == -4127)
        #expect(signals.first?.1 == SIGTERM)
    }

    @Test func setupCleanupSignalsOnlyTheMatchingGeneration() {
        var signals: [(pid_t, Int32)] = []
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { _ in expected },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return 0
            }
        ).terminateValidatedProcess(expected)

        #expect(didTerminate)
        #expect(signals.count == 1)
        #expect(signals.first?.0 == expected.pid)
        #expect(signals.first?.1 == SIGKILL)
    }

    @Test func setupCleanupRefusesAReusedGeneration() {
        var signals: [(pid_t, Int32)] = []
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { _ in replacement },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return 0
            }
        ).terminateValidatedProcess(expected)

        #expect(!didTerminate)
        #expect(signals.isEmpty)
    }

    @Test func discoveredStateCarriesTheLaunchIdentityUntilKernelValidation() throws {
        let data = try #require(
            "{\"port\":43123,\"pid\":9876,\"launchId\":\"launch-1\"}".data(using: .utf8)
        )
        let session = try #require(
            try AgentChatSidecarStateFile.parse(data, token: "token", launchId: "launch-1")
        )

        #expect(session.launchId == "launch-1")
        #expect(session.processIdentity == nil)
        #expect(session.processGroupID == nil)
    }
}
