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
    func terminationDoesNotCompleteUntilTheExactProcessGenerationExits() async {
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
        let completion = CompletionRecorder()
        let task = Task { @MainActor in
            let result = await AgentHibernationController.shared
                .terminateScopedProcessesForHibernation(
                    [termination],
                    currentProcessID: 999,
                    currentProcessGroupID: 999,
                    processIdentityProvider: { _ in identity },
                    processGroupProvider: { _ in 1 },
                    signalErrorProvider: { _, _ in nil },
                    waitForExit: { _ in
                        waitStarted.continuation.yield()
                        for await _ in allowExit.stream {
                            break
                        }
                        return true
                    }
                )
            await completion.record(result)
        }
        var waitStartedIterator = waitStarted.stream.makeAsyncIterator()
        _ = await waitStartedIterator.next()

        #expect(await completion.value == nil)

        allowExit.continuation.yield()
        allowExit.continuation.finish()
        await task.value
        #expect(await completion.value == true)
        waitStarted.continuation.finish()
    }

    @MainActor
    @Test
    func signalFailureOtherThanMissingProcessAbortsBeforeExitWait() async {
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

        let result = await AgentHibernationController.shared
            .terminateScopedProcessesForHibernation(
                [termination],
                currentProcessID: 999,
                currentProcessGroupID: 999,
                processIdentityProvider: { _ in identity },
                processGroupProvider: { _ in 1 },
                signalErrorProvider: { _, _ in EPERM },
                waitForExit: { _ in
                    Issue.record("Exit wait must not begin after a failed SIGTERM")
                    return true
                }
            )

        #expect(result == false)
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

        let didExit = await AgentHibernationController.waitForExactProcessGenerationsToExit(
            [
                .init(
                    processID: 101,
                    processIdentity: originalIdentity,
                    processGroupID: 1
                ),
            ],
            timeout: .zero,
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
