import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CLIRelayGenerationRegressionTests {
    @Test
    func inferredRelaySessionProducesAnExactAppMutationGuard() throws {
        let cli = CMUXCLI(args: [])
        let identity = try #require(AgentHookProcessIdentity(livePID: Int(getpid())))
        let terminalLifecycleID = UUID()
        let attemptID = UUID()
        let generation = try #require(cli.agentHookRelayLifecycleGeneration(
            sessionID: "inferred-session",
            environment: [
                "CMUX_TERMINAL_LIFECYCLE_ID": terminalLifecycleID.uuidString,
                "CMUX_SSH_ATTEMPT_ID": attemptID.uuidString,
            ],
            processIdentity: identity
        ))

        #expect(cli.agentHookResumeSessionID(generation) == "inferred-session")
        #expect(cli.agentMutationGuard(
            key: "rovodev",
            sessionID: generation,
            expectedPIDKey: nil,
            expectedPID: nil,
            expectedProcessIdentity: nil
        ) == .session(statusKey: "rovodev", sessionID: generation))
    }

    @Test
    func codexMonitorReplayKeepsAnExistingRelayGeneration() throws {
        let cli = CMUXCLI(args: [])
        let terminalLifecycleID = UUID()
        let attemptID = UUID()
        let token = "relay-session#relay#\(terminalLifecycleID.uuidString)"
            + "#\(attemptID.uuidString)#43210#123#456"
        let environment = [
            "CMUX_TERMINAL_LIFECYCLE_ID": terminalLifecycleID.uuidString,
            "CMUX_SSH_ATTEMPT_ID": attemptID.uuidString,
        ]

        #expect(
            cli.agentHookExistingRelayLifecycleGeneration(
                sessionID: token,
                environment: environment
            ) == token
        )
        #expect(
            cli.agentHookExistingRelayLifecycleGeneration(
                sessionID: token + "#relay#duplicate",
                environment: environment
            ) == nil
        )
    }

    @Test
    func lastTurnBaselineStoresExactRelayOwnerAndExposesPublicSessionIDSeparately() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let initialized = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "init", root.path],
            timeout: 30
        )
        #expect(initialized.status == 0, Comment(rawValue: initialized.stderr))

        let publicSessionID = "relay-session"
        let relaySessionID = "\(publicSessionID)#relay#\(UUID().uuidString)"
            + "#\(UUID().uuidString)#43210#123#456"
        try CMUXCLI(args: []).recordAgentTurnDiffBaseline(
            agent: "omp",
            sessionId: relaySessionID,
            turnId: "turn-1",
            cwd: root.path,
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            env: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        )

        let store = try JSONDecoder().decode(
            CMUXAgentTurnDiffBaselineStore.self,
            from: Data(contentsOf: root.appendingPathComponent(
                "agent-turn-diff-baselines.json",
                isDirectory: false
            ))
        )
        #expect(store.records.count == 1)
        #expect(store.records.first?.sessionId == relaySessionID)
        #expect(store.records.first?.publicSessionId == publicSessionID)
    }
}
