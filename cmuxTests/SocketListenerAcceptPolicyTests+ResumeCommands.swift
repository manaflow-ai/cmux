import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Agent resume command construction
extension SocketListenerAcceptPolicyTests {
    func testClaudeResumeCommandRoutesThroughWrapperInsteadOfCapturedRealBinary() {
        // The captured launch executable is the real claude binary
        // (CMUX_AGENT_LAUNCH_EXECUTABLE). Resuming with it directly bypasses
        // cmux's `claude` wrapper, which is what injects the hooks, so resumed
        // sessions silently lost SessionStart/Stop/Notification. Resume must use
        // the bare `claude` wrapper. https://github.com/manaflow-ai/cmux/issues/5427
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: "/tmp/cmux project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet",
                    "--permission-mode",
                    "auto"
                ],
                workingDirectory: "/tmp/cmux project",
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude config"],
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '/tmp/cmux project' 2>/dev/null || [ ! -d '/tmp/cmux project' ]; } && 'env' 'CLAUDE_CONFIG_DIR=/tmp/claude config' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' 'claude' '--resume' 'claude-session-123' '--model' 'sonnet' '--permission-mode' 'auto'"
        )
        // The captured real-binary path must not survive: it would bypass the wrapper.
        XCTAssertFalse(snapshot.resumeCommand?.contains("/opt/Claude Code/bin/claude") ?? true)
    }

    func testClaudeForkCommandRoutesThroughWrapperInsteadOfCapturedRealBinary() throws {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: "/tmp/cmux project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet",
                    "--settings",
                    #"{"hooks":{"SessionStart":[{"hooks":[{"command":"cmux claude-hook session-start"}]}]}}"#,
                    "--session-id",
                    "old-session"
                ],
                workingDirectory: "/tmp/cmux project",
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude config"],
                capturedAt: 123,
                source: "environment"
            )
        )

        // Fork mirrors resume: route through the `claude` wrapper (so hooks fire),
        // drop the captured session selectors and the stale hook --settings.
        // https://github.com/manaflow-ai/cmux/issues/5427
        let command = try XCTUnwrap(snapshot.forkCommand)
        XCTAssertTrue(command.contains("'claude' '--resume' 'claude-session-123' '--fork-session'"), command)
        XCTAssertFalse(command.contains("/opt/Claude Code/bin/claude"), command)
        XCTAssertFalse(command.contains("cmux claude-hook session-start"), command)
        XCTAssertFalse(command.contains("old-session"), command)
    }

    func testRestorableAgentResumeStartupInputEscapesNonAsciiWorkingDirectoryAsAsciiShellInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-\(UUID().uuidString)", isDirectory: true)
        let cwdURL = root
            .appendingPathComponent("中文路径", isDirectory: true)
            .appendingPathComponent("uam-service", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: cwdURL.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet"
                ],
                workingDirectory: cwdURL.path,
                environment: ["CLAUDE_CONFIG_DIR": cwdURL.path],
                capturedAt: 123,
                source: "environment"
            )
        )

        let startupInput = try XCTUnwrap(snapshot.resumeStartupInput())
        XCTAssertTrue(
            startupInput.utf8.allSatisfy { $0 < 0x80 },
            "Terminal startup input must stay ASCII-only so UTF-8 paths are reconstructed by the shell instead of being mojibaked before execution."
        )

        let command = startupInput.trimmingCharacters(in: .newlines)
        let cdCommand = try leadingCdCommand(from: command)
        try assertZshCommandChangesDirectory(cdCommand, expectedPath: cwdURL.path)
    }

    func testSessionEntryClaudeResumeCommandChangesToSessionCwdBeforeResume() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = root
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-Users-tiffanysun-fun", isDirectory: true)
            .appendingPathComponent("a22293b7-bcef-4707-8439-2f538c8517a4.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let entry = SessionEntry(
            id: "claude:a22293b7-bcef-4707-8439-2f538c8517a4",
            agent: .claude,
            sessionId: "a22293b7-bcef-4707-8439-2f538c8517a4",
            title: "resume me",
            cwd: "/Users/tiffanysun/fun",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: transcriptURL,
            specifics: .claude(
                model: nil,
                permissionMode: nil,
                configDirectoryForResume: nil
            )
        )

        XCTAssertEqual(
            entry.resumeCommand,
            "cd /Users/tiffanysun/fun && claude --resume a22293b7-bcef-4707-8439-2f538c8517a4"
        )
    }

    func testSessionEntryClaudeResumeCommandEscapesNonAsciiCwdAsAsciiShellInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-resume-\(UUID().uuidString)", isDirectory: true)
        let cwdURL = root
            .appendingPathComponent("中文路径", isDirectory: true)
            .appendingPathComponent("uam-service", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = SessionEntry(
            id: "claude:4d8cfb79-ef17-41a7-a0ac-2f0c25ac1519",
            agent: .claude,
            sessionId: "4d8cfb79-ef17-41a7-a0ac-2f0c25ac1519",
            title: "resume me",
            cwd: cwdURL.path,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: nil,
            specifics: .claude(
                model: "gpt-5.5",
                permissionMode: "bypassPermissions",
                configDirectoryForResume: nil
            )
        )

        let command = try XCTUnwrap(entry.resumeCommand)
        XCTAssertTrue(
            command.utf8.allSatisfy { $0 < 0x80 },
            "Terminal startup input must stay ASCII-only so UTF-8 paths are reconstructed by the shell instead of being mojibaked before execution."
        )

        let cdCommand = try leadingCdCommand(from: command)
        try assertZshCommandChangesDirectory(cdCommand, expectedPath: cwdURL.path)
    }

    private func leadingCdCommand(from command: String) throws -> String {
        let separator = try XCTUnwrap(command.range(of: " && "))
        return String(command[..<separator.lowerBound])
    }

    private func assertZshCommandChangesDirectory(
        _ cdCommand: String,
        expectedPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", "\(cdCommand) && pwd"]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines)
        let stderr = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(process.terminationStatus, 0, stderr ?? "", file: file, line: line)
        XCTAssertEqual(stdout, expectedPath, file: file, line: line)
    }

    func testRestorableAgentStartupInputUsesInlineCommandWhenShort() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: "/tmp/cmux project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet"
                ],
                workingDirectory: "/tmp/cmux project",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertEqual(snapshot.resumeStartupInput(), snapshot.resumeCommand.map { $0 + "\n" })
    }

    func testRestorableAgentStartupInputUsesLauncherScriptWhenCommandExceedsTerminalInputBudget() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let longPath = "/tmp/" + String(repeating: "nested-path-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/tmp/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath,
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/repo",
                environment: ["CODEX_HOME": "/tmp/codex"],
                capturedAt: 123,
                source: "environment"
            )
        )

        let input = try XCTUnwrap(snapshot.resumeStartupInput(temporaryDirectory: tempDir))
        XCTAssertLessThanOrEqual(input.utf8.count, SessionRestorableAgentSnapshot.maxInlineStartupInputBytes)
        XCTAssertTrue(input.hasPrefix("/bin/zsh '"))
        XCTAssertFalse(input.contains(longPath))

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "/bin/zsh '"
        let scriptPath = String(trimmedInput.dropFirst(prefix.count).dropLast())
        let scriptContents = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertTrue(scriptContents.contains(longPath))
        XCTAssertTrue(scriptContents.contains("'resume'"))
        XCTAssertTrue(scriptContents.contains("'019dad34-d218-7943-b81a-eddac5c87951'"))

        let attributes = try FileManager.default.attributesOfItem(atPath: scriptPath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o600)
    }

    func testRestorableAgentStartupInputSkipsOversizedCommandWhenScriptCannotBeWritten() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blockedDirectory = tempDir.appendingPathComponent("not-a-directory", isDirectory: false)
        try "occupied".write(to: blockedDirectory, atomically: true, encoding: .utf8)
        let longPath = "/tmp/" + String(repeating: "nested-path-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/tmp/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath,
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/repo",
                environment: ["CODEX_HOME": "/tmp/codex"],
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertNil(snapshot.resumeStartupInput(temporaryDirectory: blockedDirectory))
    }

    func testClaudeResumeCommandPreservesDangerouslySkipPermissionsAndObservedEnvironment() {
        let snapshot = SessionRestorableAgentSnapshot(
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

        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '/Users/lawrence/fun' 2>/dev/null || [ ! -d '/Users/lawrence/fun' ]; } && 'env' 'CLAUDE_CONFIG_DIR=/Users/lawrence/.codex-accounts/claude/_p1775010019397' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' 'claude' '--resume' '24ec0052-450c-4914-b1dd-2ee80d4bc84b' '--dangerously-load-development-channels' 'server:custom-dev-channel' '--dangerously-skip-permissions'"
        )
    }

    func testCodexResumeCommandPreservesFlagsAndDropsOriginalPrompt() {
        let snapshot = SessionRestorableAgentSnapshot(
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

        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ]; } && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'resume' '019dad34-d218-7943-b81a-eddac5c87951' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access' '--ask-for-approval' 'never' '--search'"
        )
    }

    func testCodexResumeCommandDropsStartupImagesAndPlacesSessionBeforeFlags() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019e2bb9-5544-7201-a517-d77bb00d724f",
            workingDirectory: "/Users/lawrence/fun/cmuxterm-hq",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/lawrence/.bun/bin/codex",
                arguments: [
                    "/Users/lawrence/.bun/bin/codex",
                    "resume",
                    "--yolo",
                    "--image",
                    "[Image #1]",
                    "[Image #1] cmd clicking this should open the crash file in finder",
                    "--model",
                    "gpt-5.4",
                ],
                workingDirectory: "/Users/lawrence/fun/cmuxterm-hq",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '/Users/lawrence/fun/cmuxterm-hq' 2>/dev/null || [ ! -d '/Users/lawrence/fun/cmuxterm-hq' ]; } && '/Users/lawrence/.bun/bin/codex' 'resume' '019e2bb9-5544-7201-a517-d77bb00d724f' '--yolo' '--model' 'gpt-5.4'"
        )
    }

    func testCodexTeamsResumeCommandUsesWrapperSubcommand() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
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

        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ]; } && 'env' 'CODEX_HOME=/tmp/codex home' '/usr/local/bin/cmux' 'codex-teams' 'resume' '019dad34-d218-7943-b81a-eddac5c87951' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access'"
        )
    }

    func testCodexTeamsResumeCommandDropsOriginalForkTarget() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87952",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codexTeams",
                executablePath: "/usr/local/bin/cmux",
                arguments: [
                    "/usr/local/bin/cmux",
                    "codex-teams",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--model",
                    "gpt-5.4",
                    "stale fork prompt",
                    "--sandbox",
                    "danger-full-access"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ]; } && 'env' 'CODEX_HOME=/tmp/codex home' '/usr/local/bin/cmux' 'codex-teams' 'resume' '019dad34-d218-7943-b81a-eddac5c87952' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access'"
        )
    }

}
