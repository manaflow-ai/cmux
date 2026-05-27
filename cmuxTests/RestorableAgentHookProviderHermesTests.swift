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
            "{ cd -- '/tmp/hermes repo' 2>/dev/null || [ ! -d '/tmp/hermes repo' ]; } && 'env' 'HERMES_HOME=/tmp/hermes home' '/opt/homebrew/bin/hermes' '--tui' '--model' 'anthropic/claude-sonnet-4.6' '--resume' 'hermes-session-123'"
        )
    }

    func testHermesIndexedResumeCommandPinsHermesHome() {
        let entry = SessionEntry(
            id: "hermes-agent:hermes-session-123",
            agent: .hermesAgent,
            sessionId: "hermes-session-123",
            title: "resume me",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: nil,
            specifics: .hermesAgent(
                source: "tui",
                model: "anthropic/claude-sonnet-4.6",
                hermesHome: "/tmp/hermes home"
            )
        )

        XCTAssertEqual(
            entry.resumeCommand,
            "env HERMES_HOME='/tmp/hermes home' hermes --tui --resume hermes-session-123 --model anthropic/claude-sonnet-4.6"
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
