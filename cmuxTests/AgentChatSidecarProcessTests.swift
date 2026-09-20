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

    @Test func processTableRetainsTheGroupDuringIdentityReads() {
        #expect(AgentPIDProcessIdentity.processGroupID(pid: getpid()) == getpgrp())
    }

    @Test func terminationRefusesAReusedPIDWithoutSendingSignals() {
        var signals: [(pid_t, Int32)] = []
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { _ in replacement },
            processGroupProvider: { _ in 4127 },
            processGroupExistsProvider: { _ in false },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return 0
            }
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
            processGroupExistsProvider: { _ in false },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                if signal == SIGTERM { current = nil }
                return 0
            }
        ).terminate(
            identities: [expected],
            processGroupID: 4127
        )

        #expect(didTerminate)
        #expect(signals.count == 1)
        #expect(signals.first?.0 == -4127)
        #expect(signals.first?.1 == SIGTERM)
    }

    @Test func terminationDoesNotClaimCleanupWhenGroupOutlivesItsAnchors() {
        var current: AgentPIDProcessIdentity? = expected
        var signals: [(pid_t, Int32)] = []
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { _ in current },
            processGroupProvider: { _ in 4127 },
            processGroupExistsProvider: { _ in true },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                if signal == SIGTERM { current = nil }
                return 0
            }
        ).terminate(
            identities: [expected],
            processGroupID: 4127
        )

        #expect(!didTerminate)
        #expect(signals.count == 1)
        #expect(signals.first?.1 == SIGTERM)
    }

    @Test func terminationFailsClosedWhenOneCapturedPIDWasReused() {
        let second = AgentPIDProcessIdentity(pid: 4128, startSeconds: 200, startMicroseconds: 0)
        var signals: [(pid_t, Int32)] = []
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { pid in pid == expected.pid ? expected : replacement },
            processGroupProvider: { _ in 4127 },
            processGroupExistsProvider: { _ in true },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return 0
            }
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
            processGroupExistsProvider: { _ in true },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                return 0
            }
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
            processGroupExistsProvider: { _ in true },
            signalSender: { pid, signal in
                signals.append((pid, signal))
                errno = EPERM
                return -1
            }
        ).terminate(
            identities: [expected],
            processGroupID: 4127
        )

        #expect(!didTerminate)
        #expect(signals.count == 1)
        #expect(signals.first?.0 == -4127)
        #expect(signals.first?.1 == SIGTERM)
    }

    @Test func asyncTerminationUsesInjectedDeadlineBeforeEscalating() async {
        let expected = self.expected
        let signals = OSAllocatedUnfairLock(initialState: [Int32]())
        let didTerminate = await AgentChatSidecarProcessTerminator(
            identityProvider: { _ in expected },
            processGroupProvider: { _ in 4127 },
            processGroupExistsProvider: { _ in true },
            signalSender: { _, signal in
                signals.withLock { $0.append(signal) }
                return 0
            },
            gracePeriodWaiter: { _ in true }
        ).terminateAsync(
            identities: [expected],
            processGroupID: 4127,
            waitForExit: { false }
        )

        #expect(didTerminate)
        #expect(signals.withLock { $0 } == [SIGTERM, SIGKILL])
    }

    @Test func processExitWaiterUsesTheCapturedGenerationSignal() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let processID = process.processIdentifier
        let identity = try #require(
            AgentPIDProcessIdentity.includingExitedProcess(pid: processID)
        )

        process.terminate()

        #expect(
            await AgentChatSidecarProcessTerminator.waitForProcessExit(
                pid: processID,
                identity: identity
            )
        )
    }

    @Test func ownershipUpdatePreservesSnapshotAfterFailedTermination() async {
        let completion = AgentChatSidecarProcessExitCompletion()
        let gate = AgentChatActionInFlightGate(sidecarStateFileStore: nil)
        let original = AgentChatOwnedServerSession(
            port: 43123,
            pid: 9876,
            token: "original-token",
            launchId: "original-launch"
        )
        let replacement = AgentChatOwnedServerSession(
            port: 43124,
            pid: 9877,
            token: "replacement-token",
            launchId: "replacement-launch"
        )
        #expect(await gate.updateOwnedServerSession(original))
        gate.lock.withLock { state in
            state.terminationInProgress = true
            state.terminationFailed = false
            state.terminationCompletion = completion
        }
        defer {
            gate.lock.withLock { state in
                state.terminationInProgress = false
                state.terminationFailed = false
                state.terminationCompletion = nil
            }
        }

        await completion.finish(false)
        #expect(!(await gate.updateOwnedServerSession(replacement)))
        #expect(gate.ownedServerSession() == original)

        gate.lock.withLock { state in
            state.terminationInProgress = false
            state.terminationFailed = true
            state.terminationCompletion = nil
        }
        #expect(!(await gate.updateOwnedServerSession(replacement)))
        #expect(gate.ownedServerSession() == original)
    }

    @Test func failedPreviousOwnerTerminationRejectsReplacement() async {
        let controller = AgentChatSidecarProcessController(shellPathProvider: { "/bin/sh" })
        guard let originalHandle = await controller.launch(
            command: "sleep 30",
            launchId: "original-owner",
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            environmentOverrides: [:]
        ), let replacementHandle = await controller.launch(
            command: "sleep 30",
            launchId: "replacement-owner",
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            environmentOverrides: [:]
        ) else {
            Issue.record("expected the sidecar launches to succeed")
            return
        }
        defer {
            _ = originalHandle.terminate()
            _ = replacementHandle.terminate()
        }
        let terminationAttempts = OSAllocatedUnfairLock(initialState: [String]())
        let gate = AgentChatActionInFlightGate(
            sidecarStateFileStore: nil,
            processTerminator: { process in
                terminationAttempts.withLock { $0.append(process.launchId) }
                return process.launchId != originalHandle.launchId
            }
        )
        let originalSession = AgentChatOwnedServerSession(
            port: 43123,
            pid: Int(originalHandle.rootIdentity.pid),
            token: "original-token",
            launchId: originalHandle.launchId
        )
        let replacementSession = AgentChatOwnedServerSession(
            port: 43124,
            pid: Int(replacementHandle.rootIdentity.pid),
            token: "replacement-token",
            launchId: replacementHandle.launchId
        )
        #expect(await gate.updateOwnedServer(session: originalSession, process: originalHandle))

        #expect(!(await gate.updateOwnedServer(
            session: replacementSession,
            process: replacementHandle
        )))
        #expect(gate.ownedServerSession() == originalSession)
        #expect(gate.ownedServerProcess() === originalHandle)
        let lifecycleState = gate.lock.withLock { state in
            (state.terminationInProgress, state.terminationFailed)
        }
        #expect(!lifecycleState.0)
        #expect(lifecycleState.1)
        #expect(terminationAttempts.withLock { $0 } == [
            originalHandle.launchId,
            replacementHandle.launchId,
        ])
    }

    @Test func sessionOnlyOwnershipCleansUpBeforeReplacement() async {
        let attempts = OSAllocatedUnfairLock(initialState: [String]())
        let gate = AgentChatActionInFlightGate(
            sidecarStateFileStore: nil,
            sessionTerminator: { session in
                let launchId = session.launchId ?? "<missing>"
                return attempts.withLock { values in
                    values.append(launchId)
                    return launchId != "original"
                        || values.filter { $0 == "original" }.count > 1
                }
            }
        )
        let original = AgentChatOwnedServerSession(
            port: 43123, pid: 9876, token: "original", launchId: "original"
        )
        let rejected = AgentChatOwnedServerSession(
            port: 43124, pid: 9877, token: "rejected", launchId: "rejected"
        )
        let accepted = AgentChatOwnedServerSession(
            port: 43125, pid: 9878, token: "accepted", launchId: "accepted"
        )

        #expect(await gate.updateOwnedServerSession(original))
        #expect(!(await gate.updateOwnedServerSession(rejected)))
        #expect(gate.ownedServerSession() == original)
        gate.lock.withLock { state in state.terminationFailed = false }
        #expect(await gate.updateOwnedServerSession(accepted))
        #expect(gate.ownedServerSession() == accepted)
        #expect(attempts.withLock { $0 } == ["original", "rejected", "original"])
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

    @Test func failedSpawnIdentityCaptureKillsAndReapsSuspendedChild() async {
        let pidBox = OSAllocatedUnfairLock(initialState: pid_t(0))
        defer {
            let pid = pidBox.withLock { $0 }
            guard pid > 0 else { return }
            var status: Int32 = 0
            errno = 0
            guard waitpid(pid, &status, WNOHANG) == 0 else { return }
            _ = kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }
        let controller = AgentChatSidecarProcessController(
            spawnedIdentityProvider: { pid in
                pidBox.withLock { $0 = pid }
                return nil
            },
            shellPathProvider: { "/bin/sh" }
        )

        let handle = await controller.launch(
            command: "sleep 30",
            launchId: "identity-capture-failure",
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            environmentOverrides: [:]
        )

        #expect(handle == nil)
        let spawnedPID = pidBox.withLock { $0 }
        #expect(spawnedPID > 0)
        errno = 0
        #expect(kill(spawnedPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func conflictingSpawnIdentityStillReapsOnlyTheDirectChild() async {
        let pidBox = OSAllocatedUnfairLock(initialState: pid_t(0))
        defer {
            let pid = pidBox.withLock { $0 }
            guard pid > 0 else { return }
            var status: Int32 = 0
            errno = 0
            guard waitpid(pid, &status, WNOHANG) == 0 else { return }
            _ = kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }
        let controller = AgentChatSidecarProcessController(
            spawnedIdentityProvider: { pid in
                pidBox.withLock { $0 = pid }
                // Deliberately provide a stale token. Setup cleanup must not
                // use it for a group signal, but the direct-child proof still
                // permits killing and reaping this exact spawned child.
                return AgentPIDProcessIdentity(
                    pid: pid,
                    startSeconds: 0,
                    startMicroseconds: 0
                )
            },
            shellPathProvider: { "/bin/sh" }
        )

        let handle = await controller.launch(
            command: "sleep 30",
            launchId: "conflicting-identity",
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            environmentOverrides: [:]
        )

        #expect(handle == nil)
        let spawnedPID = pidBox.withLock { $0 }
        #expect(spawnedPID > 0)
        errno = 0
        #expect(kill(spawnedPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func asyncTerminationReapsRootAfterEscalatedGroupKill() async {
        let pidBox = OSAllocatedUnfairLock(initialState: pid_t(0))
        let controller = AgentChatSidecarProcessController(
            shellPathProvider: { "/bin/sh" }
        )
        guard let handle = await controller.launch(
            command: "trap '' TERM; sleep 30",
            launchId: "escalated-termination",
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            environmentOverrides: [:]
        ) else {
            Issue.record("expected the suspended sidecar launch to succeed")
            return
        }
        pidBox.withLock { $0 = handle.rootIdentity.pid }
        defer {
            let pid = pidBox.withLock { $0 }
            guard pid > 0 else { return }
            var status: Int32 = 0
            errno = 0
            guard waitpid(pid, &status, WNOHANG) == 0 else { return }
            _ = kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }

        #expect(await handle.terminateAsync())
        errno = 0
        #expect(kill(handle.rootIdentity.pid, 0) == -1)
        #expect(errno == ESRCH)
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
