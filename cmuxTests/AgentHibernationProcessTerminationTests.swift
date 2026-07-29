import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentHibernationProcessTerminationTests {
    private actor CompletionRecorder {
        private(set) var value: Bool?

        func record(_ value: Bool) {
            self.value = value
        }
    }

    @Test
    func validatesExactProcessGenerationAndCmuxScope() throws {
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
                processArgumentsProvider: { _ in
                    Self.processArguments(workspaceID: workspaceID, panelID: panelID)
                },
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
            processArgumentsProvider: { _ in
                Self.processArguments(workspaceID: workspaceID, panelID: panelID)
            },
            processGroupProvider: { _ in 1_101 }
        )

        #expect(terminations == nil)
    }

    @Test
    func rejectsProcessOutsidePaneScope() {
        let workspaceID = UUID()
        let panelID = UUID()
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let scope = AgentHibernationController.ProcessTerminationScope(
            key: AgentHibernationPanelKey(workspaceId: workspaceID, panelId: panelID),
            processIDs: [101],
            processIdentities: [101: identity]
        )

        let terminations = AgentHibernationController.validatedScopedProcessTerminations(
            for: scope,
            processIdentityProvider: { _ in identity },
            processArgumentsProvider: { _ in
                Self.processArguments(workspaceID: workspaceID, panelID: UUID())
            },
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
            processGroupID: 1
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
            }
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
    func signalFailureOtherThanMissingProcessAbortsBeforeCommit() {
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let termination = AgentHibernationController.ScopedProcessTermination(
            processID: 101,
            processIdentity: identity,
            processGroupID: 1
        )

        let result = AgentHibernationController.shared
            .terminateScopedProcessesForHibernation(
                [termination],
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { _ in identity },
                processGroupProvider: { _ in 1 },
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
                processGroupID: 1
            ),
            AgentHibernationController.ScopedProcessTermination(
                processID: 202,
                processIdentity: secondIdentity,
                processGroupID: 1
            ),
        ]
        let waitRecorder = CompletionRecorder()

        let controller = AgentHibernationController.shared
        let result = controller
            .terminateScopedProcessesForHibernation(
                terminations,
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { pid in
                    pid == 101 ? firstIdentity : secondIdentity
                },
                processGroupProvider: { _ in 1 },
                signalErrorProvider: { target, _ in
                    target == 101 ? nil : EPERM
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
            onExit: {}
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
            processGroupID: 1
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
        let result = controller.terminateScopedProcessesForHibernation(
            [termination],
            onTeardownCommit: {
                panel.beginAgentHibernationTermination(
                    agent: agent,
                    lastActivityAt: Date(timeIntervalSince1970: 1)
                )
            },
            currentProcessID: 999,
            currentProcessGroupID: 999,
            processIdentityProvider: { _ in identity },
            processGroupProvider: { _ in 1 },
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

    private static func processArguments(
        workspaceID: UUID,
        panelID: UUID
    ) -> CmuxTopProcessArguments {
        CmuxTopProcessArguments(
            arguments: ["/usr/bin/agent"],
            environment: [
                "CMUX_WORKSPACE_ID": workspaceID.uuidString,
                "CMUX_SURFACE_ID": panelID.uuidString,
            ]
        )
    }
}
