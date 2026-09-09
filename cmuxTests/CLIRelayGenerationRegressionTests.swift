import CMUXAgentLaunch
import Foundation
import Testing

struct CLIRelayGenerationRegressionTests {
    @Test
    func inferredRelaySessionProducesAnExactGenerationToken() throws {
        let terminalLifecycleID = UUID()
        let attemptID = UUID()
        let generation = try #require(
            AgentRelayLifecycle.inferredGeneration(
                sessionID: "inferred-session",
                environment: [
                    "CMUX_TERMINAL_LIFECYCLE_ID": terminalLifecycleID.uuidString,
                    "CMUX_SSH_ATTEMPT_ID": attemptID.uuidString,
                ],
                pid: 43210,
                startSeconds: 123,
                startMicroseconds: 456
            )
        )

        #expect(
            generation
                == "inferred-session#relay#\(terminalLifecycleID.uuidString)"
                + "#\(attemptID.uuidString)#43210#123#456"
        )
        #expect(AgentRelayLifecycle.publicSessionID(generation) == "inferred-session")
    }

    @Test
    func codexMonitorReplayKeepsAnExistingRelayGeneration() throws {
        let terminalLifecycleID = UUID()
        let attemptID = UUID()
        let token = "relay-session#relay#\(terminalLifecycleID.uuidString)"
            + "#\(attemptID.uuidString)#43210#123#456"
        let environment = [
            "CMUX_TERMINAL_LIFECYCLE_ID": terminalLifecycleID.uuidString,
            "CMUX_SSH_ATTEMPT_ID": attemptID.uuidString,
        ]

        #expect(
            AgentRelayLifecycle.existingGeneration(
                sessionID: token,
                environment: environment
            ) == token
        )
        #expect(
            AgentRelayLifecycle.existingGeneration(
                sessionID: token + "#relay#duplicate",
                environment: environment
            ) == nil
        )
        #expect(
            AgentRelayLifecycle.existingGeneration(
                sessionID: token,
                environment: [
                    "CMUX_TERMINAL_LIFECYCLE_ID": UUID().uuidString,
                    "CMUX_SSH_ATTEMPT_ID": attemptID.uuidString,
                ]
            ) == nil
        )
    }
}
