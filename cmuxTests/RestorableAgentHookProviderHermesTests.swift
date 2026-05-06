import CMUXAgentLaunch
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SocketListenerAcceptPolicyTests {
    func testHermesAgentResumeCommandPreservesTUIAndHermesHome() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "hermes-session-123",
            workingDirectory: "/tmp/hermes repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "hermes-agent",
                executablePath: "/opt/homebrew/bin/hermes",
                arguments: [
                    "/opt/homebrew/bin/hermes",
                    "--tui",
                    "--model",
                    "anthropic/claude-sonnet-4.6",
                    "--resume",
                    "old-session",
                    "--source",
                    "cli",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/hermes repo",
                environment: [
                    "HERMES_HOME": "/tmp/hermes home",
                    "HERMES_API_KEY": "secret"
                ],
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd '/tmp/hermes repo' && 'env' 'HERMES_HOME=/tmp/hermes home' '/opt/homebrew/bin/hermes' '--tui' '--model' 'anthropic/claude-sonnet-4.6' '--resume' 'hermes-session-123'"
        )
    }

    func testHermesAgentSanitizerPreservesResumeSafeFlagsAndRejectsOneshot() {
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/opt/homebrew/bin/hermes",
                    "--tui",
                    "--model",
                    "anthropic/claude-sonnet-4.6",
                    "--resume",
                    "old-session",
                    "--source",
                    "cli",
                    "initial prompt should not replay"
                ],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ),
            [
                "/opt/homebrew/bin/hermes",
                "--tui",
                "--model",
                "anthropic/claude-sonnet-4.6"
            ]
        )
        XCTAssertNil(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/opt/homebrew/bin/hermes",
                    "--oneshot",
                    "do not replay"
                ],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            )
        )
    }
}
