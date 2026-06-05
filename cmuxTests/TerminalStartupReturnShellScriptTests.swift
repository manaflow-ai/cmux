import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal startup return shell script")
struct TerminalStartupReturnShellScriptTests {
    @Test("Return shell falls back to home when no working directory is supplied")
    func returnShellFallsBackToHomeForMissingWorkingDirectory() throws {
        let temp = try TemporaryScriptFixture()
        defer { temp.cleanup() }
        let resumedDirectory = try temp.createDirectory(named: "resumed-project")
        let command = "cd -- \(TerminalStartupShellQuoting.singleQuoted(resumedDirectory.path)) && " +
            #"printf 'child-pwd=%s\n' "$PWD""#
        let contents = TerminalStartupReturnShellScript.commandThenReturnLines(
            command: command,
            workingDirectory: nil
        ).joined(separator: "\n")

        try expectGeneratedScript(contents, returnsTo: .home)
        let output = try temp.runInstrumentedScript(contents)

        #expect(output.lines.contains("child-pwd=\(resumedDirectory.path)"))
        #expect(output.lines.contains("outer-pwd-before-exec=\(temp.homeDirectory.path)"))
        #expect(!output.lines.contains("outer-pwd-before-exec=/"))
    }

    @Test("Ignore-policy agent launchers return to launch cwd without forcing the agent cwd")
    func ignorePolicyAgentLauncherReturnsToLaunchDirectory() throws {
        let temp = try TemporaryScriptFixture()
        defer { temp.cleanup() }
        let launchDirectory = try temp.createDirectory(named: "agent-launch")
        let registration = CmuxVaultAgentRegistration(
            id: "issue-5391-agent",
            name: "Issue 5391 Agent",
            detect: CmuxVaultAgentDetectRule(processName: "issue-5391-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: #"/bin/zsh -fc 'printf "child-pwd=%s\n" "$PWD"' {{sessionId}}"#,
            cwd: .ignore
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("issue-5391-agent"),
            sessionId: "session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "issue-5391-agent",
                executablePath: "/bin/zsh",
                arguments: ["/bin/zsh"],
                workingDirectory: launchDirectory.path,
                environment: nil,
                capturedAt: 123,
                source: "test"
            ),
            registration: registration
        )

        let startupCommand = try #require(snapshot.resumeStartupCommand(
            fileManager: temp.fileManager,
            temporaryDirectory: temp.root
        ))
        let scriptContents = try String(
            contentsOfFile: launcherScriptPath(from: startupCommand),
            encoding: .utf8
        )

        try expectGeneratedScript(scriptContents, returnsTo: .literal(launchDirectory.path))
        let output = try temp.runInstrumentedScript(scriptContents)

        #expect(output.lines.contains("child-pwd=/"))
        #expect(output.lines.contains("outer-pwd-before-exec=\(launchDirectory.path)"))
        #expect(!output.lines.contains("outer-pwd-before-exec=/"))
    }

    @Test("Surface resume binding launchers fall back to home when cwd is empty")
    func surfaceResumeBindingLauncherFallsBackToHomeForEmptyCwd() throws {
        let temp = try TemporaryScriptFixture()
        defer { temp.cleanup() }
        let binding = SurfaceResumeBindingSnapshot(
            name: "Issue 5391 Binding",
            kind: "codex",
            command: #"/bin/zsh -fc 'printf "child-pwd=%s\n" "$PWD"'"#,
            cwd: "   ",
            source: "agent-hook",
            autoResume: true,
            updatedAt: 123
        )

        let startupCommand = try #require(binding.startupCommandWithLauncherScript(
            fileManager: temp.fileManager,
            temporaryDirectory: temp.root
        ))
        let scriptContents = try String(
            contentsOfFile: launcherScriptPath(from: startupCommand),
            encoding: .utf8
        )

        try expectGeneratedScript(scriptContents, returnsTo: .home)
        let output = try temp.runInstrumentedScript(scriptContents)

        #expect(output.lines.contains("child-pwd=/"))
        #expect(output.lines.contains("outer-pwd-before-exec=\(temp.homeDirectory.path)"))
        #expect(!output.lines.contains("outer-pwd-before-exec=/"))
    }

    private func expectGeneratedScript(_ contents: String, returnsTo directory: ExpectedReturnDirectory) throws {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let returnLine: String
        switch directory {
        case .home:
            returnLine = #"{ cd -- "${HOME}" 2>/dev/null || true; }"#
        case .literal(let path):
            returnLine = #"{ cd -- \#(TerminalStartupShellQuoting.singleQuoted(path)) 2>/dev/null || true; }"#
        }
        let returnIndex = try #require(lines.firstIndex(of: returnLine))
        let execIndex = try #require(lines.firstIndex(of: #"exec -l "$_cmux_resume_shell""#))

        #expect(returnIndex < execIndex)
    }

    private func launcherScriptPath(from startupCommand: String) throws -> String {
        let prefix = "/bin/zsh "
        #expect(startupCommand.hasPrefix(prefix))
        let token = String(startupCommand.dropFirst(prefix.count))
        return try shellSingleQuotedTokenValue(token)
    }

    private func shellSingleQuotedTokenValue(_ token: String) throws -> String {
        #expect(token.hasPrefix("'"))
        #expect(token.hasSuffix("'"))
        let body = token.dropFirst().dropLast()
        return body.replacingOccurrences(of: #"'\''"#, with: "'")
    }
}

private enum ExpectedReturnDirectory {
    case home
    case literal(String)
}

private struct TemporaryScriptFixture {
    let fileManager = FileManager.default
    let root: URL
    let homeDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-issue-5391-\(UUID().uuidString)", isDirectory: true)
        homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? fileManager.removeItem(at: root)
    }

    func createDirectory(named name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func runInstrumentedScript(_ contents: String) throws -> String {
        let instrumented = contents.replacingOccurrences(
            of: #"exec -l "$_cmux_resume_shell""#,
            with: #"printf 'outer-pwd-before-exec=%s\n' "$PWD""#
        )
        guard instrumented != contents else {
            throw InstrumentedScriptError.missingExecLine
        }
        let scriptURL = root.appendingPathComponent("instrumented-\(UUID().uuidString).zsh")
        let script = """
        #!/bin/zsh
        cd -- /
        \(instrumented)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "-i",
            "HOME=\(homeDirectory.path)",
            "PATH=/usr/bin:/bin",
            "SHELL=/bin/zsh",
            "/bin/zsh",
            scriptURL.path,
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "stderr: \(error)")
        return output
    }
}

private enum InstrumentedScriptError: Error {
    case missingExecLine
}

private extension String {
    var lines: [String] {
        split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
