import CMUXAgentLaunch
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SocketListenerAcceptPolicyTests {
    func testGeminiResumeCommandPreservesSafeFlagsAndDropsSessionSelectors() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .gemini,
            sessionId: "5839bed1-0a60-4c05-b6d1-2410d7a3741e",
            workingDirectory: "/tmp/gemini repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "gemini",
                executablePath: "/Users/example/.bun/bin/gemini",
                arguments: [
                    "/Users/example/.bun/bin/gemini",
                    "--model",
                    "gemini-2.5-pro",
                    "--resume",
                    "old-session",
                    "--sandbox",
                    "danger-full-access",
                    "--approval-mode",
                    "yolo",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/gemini repo",
                environment: [
                    "GEMINI_CLI_HOME": "/tmp/gemini home",
                    "GEMINI_API_KEY": "secret"
                ],
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '/tmp/gemini repo' 2>/dev/null || [ ! -d '/tmp/gemini repo' ]; } && 'env' 'GEMINI_CLI_HOME=/tmp/gemini home' '/Users/example/.bun/bin/gemini' '--resume' '5839bed1-0a60-4c05-b6d1-2410d7a3741e' '--model' 'gemini-2.5-pro' '--sandbox' 'danger-full-access' '--approval-mode' 'yolo'"
        )
    }

    func testAntigravityResumeCommandUsesConversationAndDropsStartupSelectors() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .antigravity,
            sessionId: "antigravity-conversation-123",
            workingDirectory: "/tmp/antigravity repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "antigravity",
                executablePath: "/Users/example/.local/bin/agy",
                arguments: [
                    "/Users/example/.local/bin/agy",
                    "--conversation",
                    "old-conversation",
                    "--sandbox",
                    "danger-full-access",
                    "--add-dir",
                    "/tmp/extra repo",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/antigravity repo",
                environment: [
                    "GEMINI_CLI_HOME": "/tmp/gemini home",
                    "GEMINI_API_KEY": "secret"
                ],
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '/tmp/antigravity repo' 2>/dev/null || [ ! -d '/tmp/antigravity repo' ]; } && 'env' 'GEMINI_CLI_HOME=/tmp/gemini home' '/Users/example/.local/bin/agy' '--conversation' 'antigravity-conversation-123' '--sandbox' 'danger-full-access' '--add-dir' '/tmp/extra repo'"
        )
    }

    func testRovoDevResumeCommandUsesRestoreAndPreservesYolo() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .rovodev,
            sessionId: "session with space",
            workingDirectory: "/tmp/rovo repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "rovodev",
                executablePath: "/opt/homebrew/bin/acli",
                arguments: [
                    "/opt/homebrew/bin/acli",
                    "rovodev",
                    "run",
                    "--restore",
                    "old-session",
                    "--yolo",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/rovo repo",
                environment: [
                    "ATLASSIAN_TOKEN": "secret",
                    "CMUX_ROVODEV_SESSIONS_DIR": "/tmp/rovo sessions"
                ],
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '/tmp/rovo repo' 2>/dev/null || [ ! -d '/tmp/rovo repo' ]; } && 'env' 'CMUX_ROVODEV_SESSIONS_DIR=/tmp/rovo sessions' '/opt/homebrew/bin/acli' 'rovodev' 'run' '--restore' 'session with space' '--yolo'"
        )
    }

    func testCursorResumeCommandDropsCapturedNodeRuntimeFlags() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .cursor,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "~/.cursor",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "cursor",
                executablePath: "/usr/local/bin/agent",
                arguments: [
                    "/usr/local/bin/agent",
                    "agent",
                    "--use-system-ca",
                    "--model",
                    "gpt-5.4",
                    "--resume",
                    "old-chat"
                ],
                workingDirectory: "~/.cursor",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '~/.cursor' 2>/dev/null || [ ! -d '~/.cursor' ]; } && '/usr/local/bin/agent' '--resume' '019dad34-d218-7943-b81a-eddac5c87951' '--model' 'gpt-5.4'"
        )
    }

    func testAdditionalHookAgentResumeCommandsUseVerifiedCLIResumeFlags() {
        let cursor = SessionRestorableAgentSnapshot(
            kind: .cursor,
            sessionId: "cursor-chat-123",
            workingDirectory: "/tmp/cursor repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "cursor",
                executablePath: "/Users/example/.local/bin/cursor-agent",
                arguments: [
                    "/Users/example/.local/bin/cursor-agent",
                    "agent",
                    "--model",
                    "gpt-5.4",
                    "--resume",
                    "old-chat",
                    "--workspace",
                    "/tmp/old repo",
                    "--sandbox",
                    "enabled",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/cursor repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
        let copilot = SessionRestorableAgentSnapshot(
            kind: .copilot,
            sessionId: "copilot-session-123",
            workingDirectory: "/tmp/copilot repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "copilot",
                executablePath: "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                arguments: [
                    "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                    "--model",
                    "gpt-5.4",
                    "--resume=old-session",
                    "--allow-all-tools",
                    "-i",
                    "old prompt",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/copilot repo",
                environment: [
                    "COPILOT_HOME": "/tmp/copilot home",
                    "COPILOT_GITHUB_TOKEN": "secret"
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let codeBuddy = SessionRestorableAgentSnapshot(
            kind: .codebuddy,
            sessionId: "codebuddy-session-123",
            workingDirectory: "/tmp/codebuddy repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codebuddy",
                executablePath: "/Users/example/.npm/bin/codebuddy",
                arguments: [
                    "/Users/example/.npm/bin/codebuddy",
                    "--model",
                    "gpt-5.4",
                    "--resume",
                    "old-session",
                    "--permission-mode",
                    "plan",
                    "--worktree",
                    "scratch",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/codebuddy repo",
                environment: [
                    "CODEBUDDY_CONFIG_DIR": "/tmp/codebuddy config",
                    "CODEBUDDY_API_KEY": "secret"
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let factory = SessionRestorableAgentSnapshot(
            kind: .factory,
            sessionId: "factory-session-123",
            workingDirectory: "/tmp/factory repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "factory",
                executablePath: "/Users/example/.npm/bin/droid",
                arguments: [
                    "/Users/example/.npm/bin/droid",
                    "--resume",
                    "old-session",
                    "--cwd",
                    "/tmp/factory repo",
                    "--append-system-prompt",
                    "be terse",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/factory repo",
                environment: [
                    "FACTORY_API_KEY": "secret"
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let qoder = SessionRestorableAgentSnapshot(
            kind: .qoder,
            sessionId: "qoder-session-123",
            workingDirectory: "/tmp/qoder repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "qoder",
                executablePath: "/Users/example/.npm/bin/qodercli",
                arguments: [
                    "/Users/example/.npm/bin/qodercli",
                    "--model",
                    "gemini-2.5-pro",
                    "--resume",
                    "old-session",
                    "--permission-mode",
                    "plan",
                    "--workspace",
                    "/tmp/qoder repo",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/qoder repo",
                environment: [
                    "QODER_CONFIG_DIR": "/tmp/qoder config",
                    "GEMINI_API_KEY": "secret"
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let kiro = SessionRestorableAgentSnapshot(
            kind: .kiro,
            sessionId: "kiro-session-123",
            workingDirectory: "/tmp/kiro repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "kiro",
                executablePath: "/Users/example/.cargo/bin/kiro-cli",
                arguments: [
                    "/Users/example/.cargo/bin/kiro-cli",
                    "chat",
                    "--agent",
                    "cmux",
                    "--resume-id",
                    "old-session",
                    "--trust-tools",
                    "fs_read,fs_write",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/kiro repo",
                environment: [
                    "KIRO_HOME": "/tmp/kiro home",
                    "AWS_SECRET_ACCESS_KEY": "secret"
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let grok = SessionRestorableAgentSnapshot(
            kind: .grok,
            sessionId: "grok-session-123",
            workingDirectory: "/tmp/grok repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "/Users/example/.grok/bin/grok",
                arguments: [
                    "/Users/example/.grok/bin/grok",
                    "--model",
                    "grok-4",
                    "--resume",
                    "old-session",
                    "--permission-mode",
                    "auto",
                    "--cwd",
                    "/tmp/grok repo",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/grok repo",
                environment: [
                    "GROK_HOME": "/tmp/grok home",
                    "XAI_API_KEY": "secret"
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let pi = SessionRestorableAgentSnapshot(
            kind: .pi, sessionId: "pi-session-123", workingDirectory: "/tmp/pi repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi", executablePath: "/Users/example/.bun/bin/pi",
                arguments: ["/Users/example/.bun/bin/pi", "--model", "anthropic/claude-sonnet-4-5", "--session", "old-session", "--thinking", "high", "initial prompt should not replay"],
                workingDirectory: "/tmp/pi repo", environment: ["PI_CODING_AGENT_DIR": "/tmp/pi home", "OPENAI_API_KEY": "secret"], capturedAt: 123, source: "process"
            )
        )
        let amp = SessionRestorableAgentSnapshot(
            kind: .amp,
            sessionId: "T-019e032c-c31a-77a9-ad87-8298ec47029f",
            workingDirectory: "/tmp/amp repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "amp",
                executablePath: "/Users/example/.local/bin/amp",
                arguments: [
                    "/Users/example/.local/bin/amp",
                    "threads",
                    "continue",
                    "T-old-thread",
                    "-l",
                    "scratch",
                    "--mode",
                    "smart",
                    "--effort",
                    "high"
                ],
                workingDirectory: "/tmp/amp repo",
                environment: ["AMP_SETTINGS_FILE": "/tmp/amp-settings.json", "OPENAI_API_KEY": "secret"],
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            cursor.resumeCommand,
            "{ cd -- '/tmp/cursor repo' 2>/dev/null || [ ! -d '/tmp/cursor repo' ]; } && '/Users/example/.local/bin/cursor-agent' '--resume' 'cursor-chat-123' '--model' 'gpt-5.4' '--sandbox' 'enabled'"
        )
        XCTAssertEqual(
            copilot.resumeCommand,
            "{ cd -- '/tmp/copilot repo' 2>/dev/null || [ ! -d '/tmp/copilot repo' ]; } && 'env' 'COPILOT_HOME=/tmp/copilot home' '/tmp/cmux-agent-upstreams/copilot-install/bin/copilot' '--resume' 'copilot-session-123' '--model' 'gpt-5.4' '--allow-all-tools'"
        )
        XCTAssertEqual(
            codeBuddy.resumeCommand,
            "{ cd -- '/tmp/codebuddy repo' 2>/dev/null || [ ! -d '/tmp/codebuddy repo' ]; } && 'env' 'CODEBUDDY_CONFIG_DIR=/tmp/codebuddy config' '/Users/example/.npm/bin/codebuddy' '--resume' 'codebuddy-session-123' '--model' 'gpt-5.4' '--permission-mode' 'plan'"
        )
        XCTAssertEqual(
            factory.resumeCommand,
            "{ cd -- '/tmp/factory repo' 2>/dev/null || [ ! -d '/tmp/factory repo' ]; } && '/Users/example/.npm/bin/droid' '--resume' 'factory-session-123' '--append-system-prompt' 'be terse'"
        )
        XCTAssertEqual(
            qoder.resumeCommand,
            "{ cd -- '/tmp/qoder repo' 2>/dev/null || [ ! -d '/tmp/qoder repo' ]; } && 'env' 'QODER_CONFIG_DIR=/tmp/qoder config' '/Users/example/.npm/bin/qodercli' '--resume' 'qoder-session-123' '--model' 'gemini-2.5-pro' '--permission-mode' 'plan'"
        )
        XCTAssertEqual(
            kiro.resumeCommand,
            "{ cd -- '/tmp/kiro repo' 2>/dev/null || [ ! -d '/tmp/kiro repo' ]; } && 'env' 'KIRO_HOME=/tmp/kiro home' '/Users/example/.cargo/bin/kiro-cli' 'chat' '--resume-id' 'kiro-session-123' '--agent' 'cmux' '--trust-tools' 'fs_read,fs_write'"
        )
        XCTAssertEqual(
            grok.resumeCommand,
            "{ cd -- '/tmp/grok repo' 2>/dev/null || [ ! -d '/tmp/grok repo' ]; } && 'env' 'GROK_HOME=/tmp/grok home' '/Users/example/.grok/bin/grok' '-r' 'grok-session-123' '--model' 'grok-4' '--permission-mode' 'auto'"
        )
        XCTAssertEqual(pi.resumeCommand, "{ cd -- '/tmp/pi repo' 2>/dev/null || [ ! -d '/tmp/pi repo' ]; } && 'env' 'PI_CODING_AGENT_DIR=/tmp/pi home' '/Users/example/.bun/bin/pi' '--session' 'pi-session-123' '--model' 'anthropic/claude-sonnet-4-5' '--thinking' 'high'")
        XCTAssertEqual(
            amp.resumeCommand,
            "{ cd -- '/tmp/amp repo' 2>/dev/null || [ ! -d '/tmp/amp repo' ]; } && 'env' 'AMP_SETTINGS_FILE=/tmp/amp-settings.json' '/Users/example/.local/bin/amp' 'threads' 'continue' '--mode' 'smart' '--effort' 'high' 'T-019e032c-c31a-77a9-ad87-8298ec47029f'"
        )
    }

    func testAgentLaunchSanitizerMatchesGeminiAndRovoResumePolicies() {
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/example/.bun/bin/gemini",
                    "--model",
                    "gemini-2.5-pro",
                    "--resume",
                    "old-session",
                    "--sandbox",
                    "danger-full-access",
                    "initial prompt should not replay"
                ],
                launcher: "gemini",
                fallbackKind: "gemini"
            ),
            [
                "/Users/example/.bun/bin/gemini",
                "--model",
                "gemini-2.5-pro",
                "--sandbox",
                "danger-full-access"
            ]
        )
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/example/.bun/bin/gemini",
                    "--resume",
                    "--worktree",
                    "/tmp/old repo",
                    "--model",
                    "gemini-2.5-pro",
                    "--sandbox",
                    "danger-full-access"
                ],
                launcher: "gemini",
                fallbackKind: "gemini"
            ),
            [
                "/Users/example/.bun/bin/gemini",
                "--model",
                "gemini-2.5-pro",
                "--sandbox",
                "danger-full-access"
            ]
        )
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/opt/homebrew/bin/acli",
                    "rovodev",
                    "run",
                    "--restore",
                    "old-session",
                    "--yolo",
                    "initial prompt should not replay"
                ],
                launcher: "rovodev",
                fallbackKind: "rovodev"
            ),
            [
                "/opt/homebrew/bin/acli",
                "rovodev",
                "run",
                "--yolo"
            ]
        )
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/opt/homebrew/bin/acli",
                    "rovodev",
                    "run",
                    "--restore",
                    "--yolo"
                ],
                launcher: "rovodev",
                fallbackKind: "rovodev"
            ),
            [
                "/opt/homebrew/bin/acli",
                "rovodev",
                "run",
                "--yolo"
            ]
        )
        XCTAssertNil(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/opt/homebrew/bin/acli",
                    "rovodev",
                    "run",
                    "--restore",
                    "old-session",
                    "--prompt",
                    "do not replay"
                ],
                launcher: "rovodev",
                fallbackKind: "rovodev"
            )
        )
    }

    func testAgentLaunchSanitizerMatchesAdditionalHookAgentResumePolicies() {
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/example/.local/bin/cursor-agent",
                    "agent",
                    "--model",
                    "gpt-5.4",
                    "--resume",
                    "old-chat",
                    "--workspace",
                    "/tmp/old repo",
                    "--sandbox",
                    "enabled",
                    "initial prompt should not replay"
                ],
                launcher: "cursor",
                fallbackKind: "cursor"
            ),
            [
                "/Users/example/.local/bin/cursor-agent",
                "--model",
                "gpt-5.4",
                "--sandbox",
                "enabled"
            ]
        )
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                    "--model",
                    "gpt-5.4",
                    "--resume=old-session",
                    "--allow-all-tools",
                    "-i",
                    "old prompt",
                    "initial prompt should not replay"
                ],
                launcher: "copilot",
                fallbackKind: "copilot"
            ),
            [
                "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                "--model",
                "gpt-5.4",
                "--allow-all-tools"
            ]
        )
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                    "--model",
                    "gpt-5.4",
                    "--allow-tool",
                    "Read"
                ],
                launcher: "copilot",
                fallbackKind: "copilot"
            ),
            [
                "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                "--model",
                "gpt-5.4",
                "--allow-tool",
                "Read"
            ]
        )
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/example/.npm/bin/codebuddy",
                    "--model",
                    "gpt-5.4",
                    "--resume",
                    "old-session",
                    "--permission-mode",
                    "plan",
                    "--worktree",
                    "scratch",
                    "initial prompt should not replay"
                ],
                launcher: "codebuddy",
                fallbackKind: "codebuddy"
            ),
            [
                "/Users/example/.npm/bin/codebuddy",
                "--model",
                "gpt-5.4",
                "--permission-mode",
                "plan"
            ]
        )
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/example/.npm/bin/droid",
                    "--resume",
                    "old-session",
                    "--cwd",
                    "/tmp/factory repo",
                    "--append-system-prompt",
                    "be terse",
                    "initial prompt should not replay"
                ],
                launcher: "factory",
                fallbackKind: "factory"
            ),
            [
                "/Users/example/.npm/bin/droid",
                "--cwd",
                "/tmp/factory repo",
                "--append-system-prompt",
                "be terse"
            ]
        )
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/example/.local/bin/amp",
                    "threads",
                    "continue",
                    "T-old-thread",
                    "--mode",
                    "smart",
                    "--effort",
                    "high"
                ],
                launcher: "amp",
                fallbackKind: "amp"
            ),
            [
                "/Users/example/.local/bin/amp",
                "--mode",
                "smart",
                "--effort",
                "high"
            ]
        )
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/example/.npm/bin/qodercli",
                    "--model",
                    "gemini-2.5-pro",
                    "--resume",
                    "old-session",
                    "--permission-mode",
                    "plan",
                    "--workspace",
                    "/tmp/qoder repo",
                    "initial prompt should not replay"
                ],
                launcher: "qoder",
                fallbackKind: "qoder"
            ),
            [
                "/Users/example/.npm/bin/qodercli",
                "--model",
                "gemini-2.5-pro",
                "--permission-mode",
                "plan",
                "--workspace",
                "/tmp/qoder repo"
            ]
        )
        XCTAssertEqual(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/example/.cargo/bin/kiro-cli",
                    "chat",
                    "--agent",
                    "cmux",
                    "--resume-id",
                    "old-session",
                    "--trust-tools",
                    "fs_read,fs_write",
                    "initial prompt should not replay"
                ],
                launcher: "kiro",
                fallbackKind: "kiro"
            ),
            [
                "/Users/example/.cargo/bin/kiro-cli",
                "--agent",
                "cmux",
                "--trust-tools",
                "fs_read,fs_write"
            ]
        )
    }
}
