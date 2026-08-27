import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHPTYAttachNoProgressRetryTests {
    private struct ProcessResult {
        let status: Int32
        let stderr: String
        let timedOut: Bool
    }

    private struct ScenarioResult {
        let attempts: String
        let policyLog: String
        let process: ProcessResult
    }

    @Test("Only pre-limit no-progress attempts preserve the surface for another retry")
    func noProgressRetryBoundary() {
        #expect(SSHPTYAttachExitCode.hasNoProgressRetryRemaining(currentRetry: 0, limit: 3))
        #expect(SSHPTYAttachExitCode.hasNoProgressRetryRemaining(currentRetry: 1, limit: 3))
        #expect(!SSHPTYAttachExitCode.hasNoProgressRetryRemaining(currentRetry: 2, limit: 3))
    }

    // Regression for #9423: the loop used to prefix the attach command with env
    // assignments, which POSIX only allows before a simple command, so a compound
    // command produced "syntax error near unexpected token `then'" and cmux ssh
    // failed before attaching.
    @Test("The no-progress loop is valid POSIX shell for compound attach commands")
    func noProgressLoopAcceptsCompoundCommands() throws {
        let compoundCommand = [
            "if [ \"$cmux_ssh_attach_no_progress_retry\" -gt 0 ]; then : || exit 1; fi",
            "printf '%s/%s\\n' \"$CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY\" \"$CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT\" >> \"$CMUX_TEST_POLICY_LOG\"",
            "exit 0",
        ].joined(separator: "\n")
        let script = SSHPTYAttachExitCode.noProgressRetryLoopLines(
            command: compoundCommand
        ).joined(separator: "\n")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-no-progress-syntax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptFile = directory.appendingPathComponent("loop.sh")
        let policyLog = directory.appendingPathComponent("policy.log")
        try Self.writeShellFile(at: scriptFile, lines: [script])

        let syntaxCheck = Self.run(
            command: "/bin/sh -n \(Self.shellQuote(scriptFile.path))",
            environment: [:]
        )
        #expect(!syntaxCheck.timedOut)
        #expect(syntaxCheck.status == 0, "\(syntaxCheck.stderr)\n\(script)")

        // The loop must still hand the budget to the command it runs.
        let execution = Self.run(
            command: "/bin/sh \(Self.shellQuote(scriptFile.path))",
            environment: ["CMUX_TEST_POLICY_LOG": policyLog.path]
        )
        #expect(execution.status == 0, "\(execution.stderr)")
        let loggedBudget = try String(contentsOf: policyLog, encoding: .utf8)
        #expect(loggedBudget == "0/3\n")
    }

    @Test("Output or a sustained connection proves bridge progress")
    func bridgeProgressClassification() {
        #expect(
            SSHPTYAttachExitCode.bridgeClosureMadeNoProgress(
                receivedLiveOutput: false,
                bridgeUptime: 1
            )
        )
        #expect(
            !SSHPTYAttachExitCode.bridgeClosureMadeNoProgress(
                receivedLiveOutput: true,
                bridgeUptime: 1
            )
        )
        #expect(
            !SSHPTYAttachExitCode.bridgeClosureMadeNoProgress(
                receivedLiveOutput: false,
                bridgeUptime: 30
            )
        )
    }

    @Test("Repeated zero-progress bridge closures stop after the health budget")
    func repeatedZeroProgressClosuresStop() throws {
        let scenario = try Self.runNoProgressScenario(
            namePrefix: "no-progress",
            decisionLines: [
                "    exit \(SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue)",
            ]
        )

        #expect(!scenario.process.timedOut, Comment(rawValue: scenario.process.stderr))
        #expect(scenario.process.status == 1, Comment(rawValue: scenario.process.stderr))
        #expect(scenario.attempts == "3")
        #expect(
            scenario.policyLog == """
            0/3
            1/3
            2/3

            """
        )
        #expect(
            scenario.process.stderr.contains("made no progress after 3 attempts"),
            Comment(rawValue: scenario.process.stderr)
        )
    }

    @Test("A normal retryable closure resets the no-progress streak")
    func normalRetryableClosureResetsNoProgressStreak() throws {
        let scenario = try Self.runNoProgressScenario(
            namePrefix: "progress-reset",
            decisionLines: [
                "    if [ \"$count\" -eq 2 ]; then exit \(SSHPTYAttachExitCode.bridgeClosedSessionRunning.rawValue); fi",
                "    exit \(SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue)",
            ]
        )

        #expect(!scenario.process.timedOut, Comment(rawValue: scenario.process.stderr))
        #expect(scenario.process.status == 1, Comment(rawValue: scenario.process.stderr))
        #expect(scenario.attempts == "5")
        #expect(
            scenario.policyLog == """
            0/3
            1/3
            0/3
            1/3
            2/3

            """
        )
    }

    @Test("A nested no-progress policy returns general retry statuses to its owner")
    func nestedPolicyReturnsGeneralRetryStatus() throws {
        let scenario = try Self.runNoProgressScenario(
            namePrefix: "nested-boundary",
            decisionLines: [
                "    if [ \"$count\" -eq 3 ]; then exit \(SSHPTYAttachExitCode.bridgeClosedSessionRunning.rawValue); fi",
                "    exit \(SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue)",
            ],
            commandBuilder: Self.nestedPolicyCommand
        )

        #expect(!scenario.process.timedOut, Comment(rawValue: scenario.process.stderr))
        #expect(
            scenario.process.status == SSHPTYAttachExitCode.bridgeClosedSessionRunning.rawValue,
            Comment(rawValue: scenario.process.stderr)
        )
        #expect(scenario.attempts == "3")
        #expect(
            scenario.policyLog == """
            0/3
            1/3
            2/3

            """
        )
    }

    @Test("A nested no-progress policy stops at the shared health budget")
    func nestedPolicyStopsRepeatedNoProgress() throws {
        let scenario = try Self.runNoProgressScenario(
            namePrefix: "nested-exhaustion",
            decisionLines: [
                "    exit \(SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue)",
            ],
            commandBuilder: Self.nestedPolicyCommand
        )

        #expect(!scenario.process.timedOut, Comment(rawValue: scenario.process.stderr))
        #expect(scenario.process.status == 1, Comment(rawValue: scenario.process.stderr))
        #expect(scenario.attempts == "3")
        #expect(
            scenario.process.stderr.contains("made no progress after 3 attempts"),
            Comment(rawValue: scenario.process.stderr)
        )
    }

    @Test("A one-attempt health budget uses a singular diagnostic")
    func oneAttemptBudgetUsesSingularDiagnostic() throws {
        let scenario = try Self.runNoProgressScenario(
            namePrefix: "singular-exhaustion",
            decisionLines: [
                "    exit \(SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue)",
            ],
            retryLimit: 1,
            commandBuilder: Self.nestedPolicyCommand
        )

        #expect(!scenario.process.timedOut, Comment(rawValue: scenario.process.stderr))
        #expect(scenario.process.status == 1, Comment(rawValue: scenario.process.stderr))
        #expect(scenario.attempts == "1")
        #expect(
            scenario.process.stderr.contains("made no progress after 1 attempt;"),
            Comment(rawValue: scenario.process.stderr)
        )
        #expect(!scenario.process.stderr.contains("1 attempts"))
    }

    private static func runNoProgressScenario(
        namePrefix: String,
        decisionLines: [String],
        retryLimit: Int = 3,
        commandBuilder: ((URL) -> String)? = nil
    ) throws -> ScenarioResult {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pty-\(namePrefix)-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("attempts")
        let policyLog = root.appendingPathComponent("policy-log")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "case \" $* \" in",
            "  *\" ssh-pty-attach \"*)",
            "    count=$(cat \"$CMUX_TEST_ATTEMPT_FILE\" 2>/dev/null || printf 0)",
            "    count=$((count + 1))",
            "    printf '%s' \"$count\" > \"$CMUX_TEST_ATTEMPT_FILE\"",
            "    printf '%s/%s\\n' \"${CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY:-missing}\" \"${CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT:-missing}\" >> \"$CMUX_TEST_POLICY_LOG\"",
        ] + decisionLines + [
            "    ;;",
            "  *) exit 0 ;;",
            "esac",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: ["#!/bin/sh", "exit 0"])
        for executable in [fakeCLI, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_TEST_POLICY_LOG"] = policyLog.path
        environment["CMUX_SSH_PTY_NO_PROGRESS_RETRY_LIMIT"] = String(retryLimit)
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "1"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "1"
        environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] = "1"

        let process = Self.run(
            command: commandBuilder?(fakeCLI) ??
                SSHPTYAttachStartupCommandBuilder.command(sessionID: "ssh-test-session"),
            environment: environment
        )

        return ScenarioResult(
            attempts: try String(contentsOf: attemptFile, encoding: .utf8),
            policyLog: try String(contentsOf: policyLog, encoding: .utf8),
            process: process
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func nestedPolicyCommand(fakeCLI: URL) -> String {
        let attachCommand = "\(shellQuote(fakeCLI.path)) ssh-pty-attach"
        let script = SSHPTYAttachExitCode.noProgressRetryLoopLines(
            command: attachCommand
        ).joined(separator: "\n")
        return "/bin/sh -c \(shellQuote(script))"
    }

    private static func writeShellFile(at url: URL, lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func run(command: String, environment: [String: String]) -> ProcessResult {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stderr: String(describing: error), timedOut: false)
        }

        let exited = DispatchSemaphore(value: 0)
        CLITestProcessRunner.detachBlockingThread(name: "cmux-test-SSHPTYAttachNoProgressRetryTests") {
            process.waitUntilExit()
            exited.signal()
        }
        let timedOut = exited.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
        }
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return ProcessResult(status: process.terminationStatus, stderr: stderr, timedOut: timedOut)
    }
}
