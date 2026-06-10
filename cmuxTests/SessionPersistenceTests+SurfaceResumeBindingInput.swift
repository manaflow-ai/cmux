import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Surface resume binding startup input
extension SessionPersistenceTests {
    func testSurfaceResumeBindingStartupInputUsesExactCommand() {
        let binding = SurfaceResumeBindingSnapshot(
            name: "OpenCode",
            kind: "opencode",
            command: "opencode --session ses_123",
            cwd: "/tmp/project",
            checkpointId: "ses_123",
            source: "cli",
            updatedAt: 1_777_777_777
        )

        XCTAssertEqual(binding.startupInput, "opencode --session ses_123\n")
    }

    func testSurfaceResumeBindingStartupInputScopesEnvironmentToCommand() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cd '/tmp/project' && codex resume session",
            environment: [
                "SPACED": "  keep exact  ",
                "CODEX_HOME": "/tmp/codex home",
                "EMPTY": "",
                "ANTHROPIC_API_KEY": "should-not-persist",
            ]
        )

        XCTAssertEqual(
            binding.startupInput,
            "'/usr/bin/env' 'CODEX_HOME=/tmp/codex home' 'EMPTY=' 'SPACED=  keep exact  ' '/bin/zsh' '-lc' 'cd '\\''/tmp/project'\\'' && codex resume session'\n"
        )
    }

    func testAgentHookSurfaceResumeBindingStoresSanitizedCommand() throws {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cd '/tmp/project' && codex resume session",
            cwd: "/tmp/project",
            source: "agent-hook",
            updatedAt: 1
        )

        XCTAssertEqual(
            binding.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session",
                workingDirectory: "/tmp/project"
            )
        )

        let decoded = try JSONDecoder().decode(
            SurfaceResumeBindingSnapshot.self,
            from: Data(
                """
                {
                  "command": "cd '/tmp/project' && codex resume session",
                  "cwd": "/tmp/project",
                  "source": "agent-hook",
                  "updatedAt": 1
                }
                """.utf8
            )
        )

        XCTAssertEqual(
            decoded.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session",
                workingDirectory: "/tmp/project"
            )
        )
    }

    func testAgentHookSurfaceResumeBindingDropsDuplicateWorkingDirectoryOption() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cd '/tmp/project' && codex resume session --append-system-prompt 'use C:\\tmp' --cd '/tmp/project' --model gpt-5.4",
            cwd: "/tmp/project",
            source: "agent-hook",
            updatedAt: 1
        )

        XCTAssertEqual(
            binding.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session --append-system-prompt 'use C:\\tmp' --model gpt-5.4",
                workingDirectory: "/tmp/project"
            )
        )
    }

    func testAgentHookSurfaceResumeBindingPreservesShellOperatorsWhenDroppingDuplicateWorkingDirectoryOption() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cd '/tmp/project' && codex resume session --cd '/tmp/project' && echo done",
            cwd: "/tmp/project",
            source: "agent-hook",
            updatedAt: 1
        )

        XCTAssertEqual(
            binding.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session && echo done",
                workingDirectory: "/tmp/project"
            )
        )
        XCTAssertFalse(binding.command.contains("'&&'"), binding.command)
    }

    func testAgentHookSurfaceResumeBindingCanonicalizesLegacyGuardForNonASCIIWorkingDirectory() {
        let cwd = "/tmp/\u{4E2D}\u{6587}\u{8DEF}\u{5F84}"
        let legacyQuotedCwd = "'\(cwd)'"
        let binding = SurfaceResumeBindingSnapshot(
            command: "{ cd -- \(legacyQuotedCwd) 2>/dev/null || [ ! -d \(legacyQuotedCwd) ]; } && codex resume session",
            cwd: cwd,
            source: "agent-hook",
            updatedAt: 1
        )

        XCTAssertEqual(
            binding.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session",
                workingDirectory: cwd
            )
        )
        XCTAssertFalse(binding.command.contains(legacyQuotedCwd), binding.command)
    }

    func testAgentHookSurfaceResumeStartupInputRunsWhenSavedWorkingDirectoryWasDeleted() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-missing-cwd-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let deletedCwd = root.appendingPathComponent("deleted", isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        let outputURL = root.appendingPathComponent("codex-output.txt", isDirectory: false)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCodex = bin.appendingPathComponent("codex", isDirectory: false)
        try """
        #!/bin/zsh
        print -r -- "$PWD|$*" > "$CMUX_FAKE_CODEX_OUTPUT"
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "cd '\(deletedCwd.path)' && codex resume session-duplicate-turn --yolo",
            cwd: deletedCwd.path,
            checkpointId: "session-duplicate-turn",
            source: "agent-hook",
            environment: [
                "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude-profile", isDirectory: true).path
            ],
            autoResume: true
        )

        let startupInput = try XCTUnwrap(binding.startupInput)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", startupInput]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_FAKE_CODEX_OUTPUT"] = outputURL.path
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(output.contains("resume session-duplicate-turn --yolo"), output)
        XCTAssertFalse(output.hasPrefix("\(deletedCwd.path)|"), output)
    }

    func testSurfaceResumeBindingStartupInputUsesLauncherScriptWhenLong() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let longPath = "/tmp/" + String(repeating: "nested-path-", count: 120)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume session --add-dir \(longPath)",
            environment: [
                "CODEX_HOME": "/tmp/codex home",
            ]
        )

        let inlineInput = try XCTUnwrap(binding.inlineStartupInput)
        XCTAssertGreaterThan(inlineInput.utf8.count, SurfaceResumeBindingSnapshot.maxInlineStartupInputBytes)

        let input = try XCTUnwrap(binding.startupInputWithLauncherScript(temporaryDirectory: tempDir))
        XCTAssertLessThanOrEqual(input.utf8.count, SurfaceResumeBindingSnapshot.maxInlineStartupInputBytes)
        XCTAssertTrue(input.hasPrefix("/bin/zsh '"))
        XCTAssertFalse(input.contains(longPath))

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "/bin/zsh '"
        let scriptPath = String(trimmedInput.dropFirst(prefix.count).dropLast())
        let scriptContents = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertTrue(scriptContents.contains(longPath))
        XCTAssertTrue(scriptContents.contains("'CODEX_HOME=/tmp/codex home'"))
        XCTAssertTrue(scriptContents.contains("codex resume session"))
    }

}
