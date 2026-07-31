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
                    "gpt-5.4",
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
            "cd -- '/tmp/hermes repo' 2>/dev/null || [ ! -d '/tmp/hermes repo' ] && 'env' 'HERMES_HOME=/tmp/hermes home' '/opt/homebrew/bin/hermes' '--tui' '--model' 'gpt-5.4' '--resume' 'hermes-session-123'"
        )
    }

    func testHermesAgentResumeCommandRewritesStaleCodexProvider() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "hermes-session-123",
            workingDirectory: "/tmp/hermes repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "hermes-agent",
                executablePath: "/opt/homebrew/bin/hermes",
                arguments: [
                    "/opt/homebrew/bin/hermes",
                    "--provider",
                    "openai-codex",
                    "--model",
                    "gpt-5.5",
                ],
                workingDirectory: "/tmp/hermes repo",
                environment: [:],
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd -- '/tmp/hermes repo' 2>/dev/null || [ ! -d '/tmp/hermes repo' ] && '/opt/homebrew/bin/hermes' '--provider' 'custom' '--model' 'gpt-5.5' '--resume' 'hermes-session-123'"
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
                model: "gpt-5.4",
                hermesHome: "/tmp/hermes home"
            )
        )

        XCTAssertEqual(
            entry.resumeCommand,
            "env HERMES_HOME='/tmp/hermes home' hermes --tui --resume hermes-session-123 --model gpt-5.4"
        )
    }

    func testHermesAgentResumeCommandPreservesSubrouterBaseURLs() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "hermes-session-123",
            workingDirectory: "/tmp/hermes repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "hermes-agent",
                executablePath: "/opt/homebrew/bin/hermes",
                arguments: [
                    "/opt/homebrew/bin/hermes",
                    "--provider",
                    "anthropic",
                    "--model",
                    "anthropic/claude-sonnet-4.6",
                ],
                workingDirectory: "/tmp/hermes repo",
                environment: [
                    "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
                    "HERMES_CODEX_BASE_URL": "http://subrouter-team:31415/backend-api/codex",
                    "HERMES_HOME": "/tmp/hermes home",
                ],
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd -- '/tmp/hermes repo' 2>/dev/null || [ ! -d '/tmp/hermes repo' ] && 'env' 'CUSTOM_BASE_URL=http://subrouter-team:31415/v1' 'HERMES_CODEX_BASE_URL=http://subrouter-team:31415/backend-api/codex' 'HERMES_HOME=/tmp/hermes home' '/opt/homebrew/bin/hermes' '--provider' 'anthropic' '--model' 'anthropic/claude-sonnet-4.6' '--resume' 'hermes-session-123'"
        )
    }

    func testHermesAgentSanitizerPreservesResumeSafeFlagsAndRejectsOneshot() {
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/opt/homebrew/bin/hermes",
                    "--tui",
                    "--model",
                    "gpt-5.4",
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
                "gpt-5.4"
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
