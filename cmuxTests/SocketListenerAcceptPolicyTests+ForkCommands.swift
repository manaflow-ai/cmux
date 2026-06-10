import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Agent fork commands and fork support probes
extension SocketListenerAcceptPolicyTests {
    func testForkCommandsUseVerifiedAgentForkSyntaxAndPreserveContext() {
        let claude = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "24ec0052-450c-4914-b1dd-2ee80d4bc84b",
            workingDirectory: "/Users/lawrence/fun",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/Users/lawrence/.local/bin/claude",
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--dangerously-load-development-channels",
                    "server:custom-dev-channel",
                    "--dangerously-skip-permissions"
                ],
                workingDirectory: "/Users/lawrence/fun",
                environment: [
                    "CLAUDE_CONFIG_DIR": "/Users/lawrence/.codex-accounts/claude/_p1775010019397",
                    "PATH": "/Users/lawrence/.local/bin:/usr/bin",
                    "SHELL": "/bin/zsh"
                ],
                capturedAt: 123,
                source: "environment"
            )
        )
        let claudeFork = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-fork-child",
            workingDirectory: "/Users/lawrence/fun",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/Users/lawrence/.local/bin/claude",
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--resume",
                    "24ec0052-450c-4914-b1dd-2ee80d4bc84b",
                    "--fork-session",
                    "--model",
                    "sonnet",
                    "--dangerously-skip-permissions"
                ],
                workingDirectory: "/Users/lawrence/fun",
                environment: [
                    "CLAUDE_CONFIG_DIR": "/Users/lawrence/.codex-accounts/claude/_p1775010019397"
                ],
                capturedAt: 123,
                source: "environment"
            )
        )
        let codex = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--sandbox",
                    "danger-full-access",
                    "--ask-for-approval",
                    "never",
                    "--search",
                    "--cd",
                    "/Users/example/repo",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "process"
            )
        )
        let codexWithImage = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019image-session",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--image",
                    "/tmp/screenshot.png",
                    "--model",
                    "gpt-5.4",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "process"
            )
        )
        let codexFork = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019e1eca-ee32-7001-ab30-edcae57430bb",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--model",
                    "gpt-5.4",
                    "--sandbox",
                    "danger-full-access",
                    "stale fork prompt",
                    "--search"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "process"
            )
        )
        let codexTeams = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-teams-session",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codexTeams",
                executablePath: "/usr/local/bin/cmux",
                arguments: [
                    "/usr/local/bin/cmux",
                    "codex-teams",
                    "--model",
                    "gpt-5.4",
                    "--image",
                    "/tmp/team screenshot.png",
                    "--sandbox",
                    "danger-full-access",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let directOpenCode = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "direct-opencode-session-456",
            workingDirectory: "/tmp/direct opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: [
                    "/opt/homebrew/bin/opencode",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "--session",
                    "old-session",
                    "--prompt",
                    "old prompt",
                    "--port",
                    "4096",
                    "/tmp/direct opencode repo",
                    "initial prompt"
                ],
                workingDirectory: "/tmp/direct opencode repo",
                environment: ["OPENCODE_CONFIG_DIR": "/tmp/opencode config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let directOpenCodeFork = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "direct-opencode-child-session",
            workingDirectory: "/tmp/direct opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: [
                    "/opt/homebrew/bin/opencode",
                    "--session",
                    "direct-opencode-session-456",
                    "--fork",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "--port",
                    "4096",
                    "/tmp/direct opencode repo"
                ],
                workingDirectory: "/tmp/direct opencode repo",
                environment: ["OPENCODE_CONFIG_DIR": "/tmp/opencode config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let omoOpenCode = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-123",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omo",
                executablePath: "/usr/local/bin/cmux",
                arguments: [
                    "/usr/local/bin/cmux",
                    "omo",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "/tmp/opencode repo",
                    "initial prompt"
                ],
                workingDirectory: "/tmp/opencode repo",
                environment: ["OPENCODE_CONFIG_DIR": "/tmp/opencode config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let omoOpenCodeFork = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-child-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omo",
                executablePath: "/usr/local/bin/cmux",
                arguments: [
                    "/usr/local/bin/cmux",
                    "omo",
                    "--session",
                    "opencode-session-123",
                    "--fork",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "/tmp/opencode repo"
                ],
                workingDirectory: "/tmp/opencode repo",
                environment: ["OPENCODE_CONFIG_DIR": "/tmp/opencode config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let unsupported = SessionRestorableAgentSnapshot(
            kind: .gemini,
            sessionId: "gemini-session",
            workingDirectory: "/tmp/gemini repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "gemini",
                executablePath: "gemini",
                arguments: ["gemini"],
                workingDirectory: "/tmp/gemini repo",
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )

        XCTAssertEqual(
            claude.forkCommand,
            "{ cd -- '/Users/lawrence/fun' 2>/dev/null || [ ! -d '/Users/lawrence/fun' ]; } && 'env' 'CLAUDE_CONFIG_DIR=/Users/lawrence/.codex-accounts/claude/_p1775010019397' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' 'claude' '--resume' '24ec0052-450c-4914-b1dd-2ee80d4bc84b' '--fork-session' '--dangerously-load-development-channels' 'server:custom-dev-channel' '--dangerously-skip-permissions'"
        )
        XCTAssertEqual(
            claudeFork.forkCommand,
            "{ cd -- '/Users/lawrence/fun' 2>/dev/null || [ ! -d '/Users/lawrence/fun' ]; } && 'env' 'CLAUDE_CONFIG_DIR=/Users/lawrence/.codex-accounts/claude/_p1775010019397' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' 'claude' '--resume' 'claude-fork-child' '--fork-session' '--model' 'sonnet' '--dangerously-skip-permissions'"
        )
        XCTAssertEqual(
            codex.forkCommand,
            "{ cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ]; } && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access' '--ask-for-approval' 'never' '--search'"
        )
        XCTAssertEqual(
            codexWithImage.forkCommand,
            "{ cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ]; } && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'fork' '019image-session' '--model' 'gpt-5.4'"
        )
        XCTAssertEqual(
            codexFork.forkCommand,
            "{ cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ]; } && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'fork' '019e1eca-ee32-7001-ab30-edcae57430bb' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access' '--search'"
        )
        XCTAssertEqual(
            codexTeams.forkCommand,
            "{ cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ]; } && 'env' 'CODEX_HOME=/tmp/codex home' '/usr/local/bin/cmux' 'codex-teams' 'fork' 'codex-teams-session' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access'"
        )
        XCTAssertEqual(
            directOpenCode.forkCommand,
            "{ cd -- '/tmp/direct opencode repo' 2>/dev/null || [ ! -d '/tmp/direct opencode repo' ]; } && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/opt/homebrew/bin/opencode' '--session' 'direct-opencode-session-456' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '--port' '4096' '/tmp/direct opencode repo'"
        )
        XCTAssertEqual(
            directOpenCodeFork.forkCommand,
            "{ cd -- '/tmp/direct opencode repo' 2>/dev/null || [ ! -d '/tmp/direct opencode repo' ]; } && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/opt/homebrew/bin/opencode' '--session' 'direct-opencode-child-session' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '--port' '4096' '/tmp/direct opencode repo'"
        )
        XCTAssertEqual(
            omoOpenCode.forkCommand,
            "{ cd -- '/tmp/opencode repo' 2>/dev/null || [ ! -d '/tmp/opencode repo' ]; } && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/usr/local/bin/cmux' 'omo' '--session' 'opencode-session-123' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '/tmp/opencode repo'"
        )
        XCTAssertEqual(
            omoOpenCodeFork.forkCommand,
            "{ cd -- '/tmp/opencode repo' 2>/dev/null || [ ! -d '/tmp/opencode repo' ]; } && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/usr/local/bin/cmux' 'omo' '--session' 'opencode-child-session' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '/tmp/opencode repo'"
        )
        XCTAssertNil(unsupported.forkCommand)
    }

    func testOpenCodeForkSupportRequiresVersionWithForkFix() {
        XCTAssertFalse(AgentForkSupport.openCodeVersionSupportsFork("opencode 1.14.48"))
        XCTAssertTrue(AgentForkSupport.openCodeVersionSupportsFork("opencode 1.14.50"))
        XCTAssertTrue(AgentForkSupport.openCodeVersionSupportsFork("opencode version 1.15.0"))
        XCTAssertFalse(AgentForkSupport.openCodeVersionSupportsFork("not a version"))
    }

    func testOpenCodeForkSupportProbesFromLaunchWorkingDirectory() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-opencode-probe-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        echo 'opencode 1.14.50'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-123",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "opencode",
                arguments: ["opencode"],
                workingDirectory: root.path,
                environment: ["PATH": ".:/usr/bin:/bin"],
                capturedAt: 123,
                source: "process"
            )
        )

        let supportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        XCTAssertTrue(supportsFork)
    }

    func testOpenCodeForkSupportSkipsLocalProbeForRemoteLikeContext() async {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-remote",
            workingDirectory: "/remote/cmux/project-\(UUID().uuidString)",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/remote/bin/opencode",
                arguments: ["/remote/bin/opencode"],
                workingDirectory: "/remote/cmux/project-\(UUID().uuidString)",
                environment: ["PATH": "/remote/bin:/usr/bin"],
                capturedAt: 123,
                source: "process"
            )
        )

        let supportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        XCTAssertTrue(supportsFork)
    }

    func testAgentForkSupportRejectsRemoteForksThatNeedLauncherScript() async {
        let longPath = "/Users/cmux/" + String(repeating: "nested-project-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath
                ],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertNotNil(snapshot.forkStartupInput(allowLauncherScript: true))
        XCTAssertNil(snapshot.forkStartupInput(allowLauncherScript: false))
        let supportsFork = await AgentForkSupport.supportsFork(
            snapshot: snapshot,
            isRemoteContext: true
        )
        XCTAssertFalse(supportsFork)
    }

    func testOpenCodeForkSupportRemoteContextBypassesLocalProbe() async {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-remote-context",
            workingDirectory: FileManager.default.temporaryDirectory.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/bin/false",
                arguments: ["/bin/false"],
                workingDirectory: FileManager.default.temporaryDirectory.path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let supportsFork = await AgentForkSupport.supportsFork(
            snapshot: snapshot,
            isRemoteContext: true
        )
        XCTAssertTrue(supportsFork)
    }

    func testOpenCodeForkSupportRejectsMissingLocalExecutable() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-opencode-missing-executable-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let missingExecutable = root.appendingPathComponent("missing-opencode", isDirectory: false)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-missing-executable",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: missingExecutable.path,
                arguments: [missingExecutable.path],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let supportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        XCTAssertFalse(supportsFork)
    }

    func testOpenCodeForkSupportCachesUnsupportedVersion() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-opencode-probe-cache-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        let versionFile = root.appendingPathComponent("version.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        cat "\(versionFile.path)"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-cache",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "opencode",
                arguments: ["opencode"],
                workingDirectory: root.path,
                environment: ["PATH": "\(root.path):/usr/bin:/bin"],
                capturedAt: 123,
                source: "process"
            )
        )

        try "opencode 1.14.48\n".write(to: versionFile, atomically: true, encoding: .utf8)
        let unsupportedVersionSupportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        XCTAssertFalse(unsupportedVersionSupportsFork)

        try "opencode 1.14.50\n".write(to: versionFile, atomically: true, encoding: .utf8)
        let supportedVersionSupportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        XCTAssertFalse(supportedVersionSupportsFork)
    }

    func testOpenCodeVersionProbeEnvironmentIsSanitized() {
        let environment = AgentForkSupport.processEnvironmentForOpenCodeProbe(
            environment: [
                "PATH": "/tmp/project/bin:/usr/bin",
                "OPENCODE_CONFIG_DIR": "/tmp/opencode-config",
                "ANTHROPIC_API_KEY": "captured-secret",
            ],
            baseEnvironment: [
                "PATH": "/usr/local/bin:/usr/bin",
                "HOME": "/Users/example",
                "TMPDIR": "/tmp/example",
                "LANG": "en_US.UTF-8",
                "AWS_SECRET_ACCESS_KEY": "app-secret",
                "ANTHROPIC_API_KEY": "app-secret",
            ]
        )

        XCTAssertEqual(environment["PATH"], "/tmp/project/bin:/usr/bin")
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["TMPDIR"], "/tmp/example")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["OPENCODE_CONFIG_DIR"], "/tmp/opencode-config")
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
    }

}
