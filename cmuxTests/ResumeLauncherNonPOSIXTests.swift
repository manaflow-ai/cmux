import Foundation
import Testing
import CmuxCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) struct ResumeLauncherNonPOSIXTests {
    @Test func resumeLauncherWrapsCommandForNonPOSIXLoginShells() {
        let command = "{ cd -- '/tmp/x' 2>/dev/null || [ ! -d '/tmp/x' ]; } && 'claude' '--resume' 'abc'"
        let lines = TerminalStartupReturnShellScript.commandThenReturnLines(command: command)

        func caseBranch(_ marker: String) -> String {
            lines.first { $0.contains(marker) && $0.contains("$_cmux_resume_shell") } ?? ""
        }

        let fishBranch = caseBranch("*)")
        let cshBranch = caseBranch("csh|tcsh)")
        let posixBranch = caseBranch("zsh|bash)")

        #expect(!fishBranch.isEmpty, "expected a fish/default case branch; script:\n\(lines.joined(separator: "\n"))")
        #expect(!cshBranch.isEmpty, "expected a csh/tcsh case branch; script:\n\(lines.joined(separator: "\n"))")
        #expect(!posixBranch.isEmpty, "expected a zsh/bash case branch; script:\n\(lines.joined(separator: "\n"))")

        #expect(fishBranch.contains("-c '/bin/sh -c "), "fish branch must wrap via /bin/sh -c:\n\(fishBranch)")
        #expect(cshBranch.contains("-c '/bin/sh -c "), "csh/tcsh branch must wrap via /bin/sh -c:\n\(cshBranch)")
        #expect(!fishBranch.contains("-c '{ "), "fish branch must not hand the raw grouping to fish:\n\(fishBranch)")
        #expect(!cshBranch.contains("-c '{ "), "csh/tcsh branch must not hand the raw grouping to csh:\n\(cshBranch)")

        #expect(posixBranch.contains("-lic '{ "), "zsh/bash must keep running the POSIX command natively:\n\(posixBranch)")
        #expect(!posixBranch.contains("/bin/sh -c"), "zsh/bash must not be wrapped:\n\(posixBranch)")
    }

    @Test func claudeResumeCommandWithWorkingDirectoryExecutesThroughWrapperInsideTcshLauncher() throws {
        let tcshURL = URL(fileURLWithPath: "/bin/tcsh")
        guard FileManager.default.isExecutableFile(atPath: tcshURL.path) else {
            return
        }

        let sandbox = try makeClaudeResumeWrapperShimSandbox()
        defer { sandbox.removeSandbox() }
        try (
            "set path = (\(shellQuotedForTest(sandbox.realBinDirectoryURL.path)) /usr/bin /bin)\n"
                + "alias claude \(shellQuotedForTest(sandbox.realClaudeURL.path))\n"
        ).write(to: sandbox.homeURL.appendingPathComponent(".tcshrc"), atomically: true, encoding: .utf8)

        let snapshot = makeClaudeRestorableSnapshot(workingDirectory: sandbox.sandboxURL.path)
        let resumeCommand = try #require(snapshot.resumeCommand)
        #expect(resumeCommand.contains("cd -- "), "this regression requires the cwd guard to be present; resumeCommand: \(resumeCommand)")
        #expect(!resumeCommand.contains("{ cd -- "), "the cwd guard should use the brace-free portable form; resumeCommand: \(resumeCommand)")

        let recorded = try runClaudeResumeCommand(
            resumeCommand,
            shellURL: tcshURL,
            arguments: ["-c"],
            sandbox: sandbox
        )
        #expect(
            recorded.hasPrefix("wrapper "),
            "tcsh-dispatched guard-bearing resume must parse and exec the cmux wrapper. Recorded invocation: \(recorded.isEmpty ? "<none>" : recorded)"
        )
        #expect(
            recorded.contains("--settings"),
            "tcsh-dispatched guard-bearing resume must re-inject the hook --settings via the wrapper. Recorded invocation: \(recorded.isEmpty ? "<none>" : recorded)"
        )
    }

    private struct ClaudeResumeWrapperShimSandbox {
        let sandboxURL: URL
        let homeURL: URL
        let realBinDirectoryURL: URL
        let realClaudeURL: URL
        let shimURL: URL
        let recordURL: URL

        func removeSandbox() {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    private func makeClaudeResumeWrapperShimSandbox() throws -> ClaudeResumeWrapperShimSandbox {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-6285-\(UUID().uuidString)", isDirectory: true)
        let shimDir = sandbox.appendingPathComponent("cmux-cli-shims", isDirectory: true)
        let realBinDir = sandbox.appendingPathComponent("realbin", isDirectory: true)
        let userHome = sandbox.appendingPathComponent("home", isDirectory: true)
        for dir in [shimDir, realBinDir, userHome] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let recordURL = sandbox.appendingPathComponent("record.txt", isDirectory: false)
        let wrapperURL = sandbox.appendingPathComponent("cmux-claude-wrapper", isDirectory: false)
        let shimURL = shimDir.appendingPathComponent("claude", isDirectory: false)
        let realClaudeURL = realBinDir.appendingPathComponent("claude", isDirectory: false)

        func writeExecutable(_ url: URL, _ contents: String) throws {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        try writeExecutable(wrapperURL, """
        #!/usr/bin/env bash
        set -- "$@"
        for arg in "$@"; do
          if [[ "$arg" == "--resume" || "$arg" == "-r" ]]; then
            set -- --settings CMUX_HOOKS_JSON "$@"
            break
          fi
        done
        printf 'wrapper %s\\n' "$*" > \(shellQuotedForTest(recordURL.path))
        """)
        try writeExecutable(shimURL, """
        #!/usr/bin/env bash
        exec \(shellQuotedForTest(wrapperURL.path)) "$@"
        """)
        try writeExecutable(realClaudeURL, """
        #!/usr/bin/env bash
        printf 'real %s\\n' "$*" > \(shellQuotedForTest(recordURL.path))
        """)

        return ClaudeResumeWrapperShimSandbox(
            sandboxURL: sandbox,
            homeURL: userHome,
            realBinDirectoryURL: realBinDir,
            realClaudeURL: realClaudeURL,
            shimURL: shimURL,
            recordURL: recordURL
        )
    }

    private func makeClaudeRestorableSnapshot(workingDirectory: String?) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet"
                ],
                workingDirectory: workingDirectory,
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude config"],
                capturedAt: 123,
                source: "environment"
            )
        )
    }

    private func runClaudeResumeCommand(
        _ resumeCommand: String,
        shellURL: URL,
        arguments: [String],
        sandbox: ClaudeResumeWrapperShimSandbox
    ) throws -> String {
        let process = Process()
        process.executableURL = shellURL
        let shellLeaf = shellURL.lastPathComponent
        let dispatchedCommand = (shellLeaf == "zsh" || shellLeaf == "bash")
            ? resumeCommand
            : TerminalStartupReturnShellScript.posixShellDispatchCommand(resumeCommand)
        process.arguments = arguments + [dispatchedCommand]
        process.environment = [
            "HOME": sandbox.homeURL.path,
            "CMUX_CLAUDE_WRAPPER_SHIM": sandbox.shimURL.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runWithBoundedWait(process, shellDescription: shellURL.path)
        return (try? String(contentsOf: sandbox.recordURL, encoding: .utf8)) ?? ""
    }

    private struct ResumeLauncherTestError: Error, CustomStringConvertible {
        let description: String
    }

    private func runWithBoundedWait(
        _ process: Process,
        shellDescription: String,
        timeout: TimeInterval = 30
    ) throws {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw ResumeLauncherTestError(
                description: "Resume shell (\(shellDescription)) did not exit within \(Int(timeout))s; treating as hung."
            )
        }
    }

    private func shellQuotedForTest(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
