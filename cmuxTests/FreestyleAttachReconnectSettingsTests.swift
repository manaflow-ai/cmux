import CmuxCore
import CmuxRemoteWorkspace
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Cloud VM attach loop must read `CMUX_SSH_RECONNECT_LIMIT` and
/// `CMUX_SSH_RECONNECT_DELAY_SECONDS` the way the ssh attach supervisor does
/// (https://github.com/manaflow-ai/cmux/issues/10419).
///
/// The loop passed both straight to the shell: an oversized limit made `[ -ge ]`
/// fail on every retry, so the budget bounded nothing, and a delay `sleep`
/// rejects, including one too long for it, made the loop retry with no wait.
/// Each test runs the startup command the app really builds under `/bin/sh`,
/// with a stand-in cmux CLI whose attach fails as retryable (255) and a
/// stand-in `sleep` that records what it was asked to wait.
@MainActor
@Suite(.serialized)
struct FreestyleAttachReconnectSettingsTests {
    /// The two app-built loops: a live workspace on the default Cloud VM, and the
    /// one a restored session snapshot gets.
    private static func startupCommands() throws -> [(name: String, command: String)] {
        let workspace = Workspace()
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cloud VM",
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            managedCloudVMID: "71smiccrg35sw9pydt8k",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "cmux-default-freestyle-sshd-v1",
            skipDaemonBootstrap: true
        )
        let live = try #require(workspace.effectiveRemoteTerminalStartupCommand(from: configuration))

        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "nncop8f8h6w9blhns6sy+cmux@vm-ssh.freestyle.sh",
            port: 22,
            identityFile: nil,
            sshOptions: [],
            preserveAfterTerminalExit: nil,
            skipDaemonBootstrap: true,
            relayPort: nil,
            persistentDaemonSlot: nil,
            managedCloudVMID: "nncop8f8h6w9blhns6sy"
        )
        let restored = try #require(snapshot.workspaceConfiguration()?.terminalStartupCommand)

        for command in [live, restored] {
            try #require(command.contains("vm-pty-attach") && command.contains("CMUX_SSH_RECONNECT_LIMIT"),
                         "not the Cloud VM attach loop: \(command)")
        }
        return [("workspace", live), ("restore", restored)]
    }

    private struct LoopRun {
        let attempts: Int
        /// The argument of each `sleep` the loop ran, in order.
        let sleeps: [String]
        let stderr: String
        let finished: Bool
    }

    /// Runs `command` with the given reconnect settings. The stand-in CLI fails
    /// retryable (255) for its first `failingAttempts` runs and then succeeds, and a
    /// stand-in `sleep` records the delay it is given and returns at once, so no
    /// result depends on how long anything took. `deadline` only stops a loop that
    /// would otherwise never end.
    private static func run(
        _ command: String,
        environment extra: [String: String],
        failingAttempts: Int = 1_000_000,
        deadline: TimeInterval = 10
    ) throws -> LoopRun {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("freestyle-reconnect-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = root.appendingPathComponent("calls")
        let slept = root.appendingPathComponent("slept")
        let cli = root.appendingPathComponent("cmux")
        try """
        #!/bin/sh
        echo attach >> '\(calls.path)'
        [ "$(/usr/bin/wc -l < '\(calls.path)')" -gt \(failingAttempts) ] && exit 0
        exit 255
        """.write(to: cli, atomically: true, encoding: .utf8)
        let sleep = bin.appendingPathComponent("sleep")
        try "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '\(slept.path)'\n".write(to: sleep, atomically: true, encoding: .utf8)
        for executable in [cli, sleep] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin",
            "HOME": root.path,
            "CMUX_BUNDLED_CLI_PATH": cli.path,
        ].merging(extra) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrURL = root.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: stderrURL)

        let started = Date()
        try process.run()
        while process.isRunning, Date().timeIntervalSince(started) < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let finished = !process.isRunning
        if !finished {
            process.terminate()
            process.waitUntilExit()
        }
        func lines(_ url: URL) -> [String] {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return LoopRun(attempts: lines(calls).count, sleeps: lines(slept), stderr: stderr, finished: finished)
    }

    private static func notices(of setting: String, in stderr: String) -> Int {
        stderr.components(separatedBy: setting).count - 1
    }

    /// `sleep` rejects `abc` at once, so the loop retried without waiting. It must
    /// wait the default 2 seconds instead, and say so once.
    @Test func aDelaySleepCannotReadIsReplacedByTheDefaultWait() throws {
        for (name, command) in try Self.startupCommands() {
            let run = try Self.run(command, environment: [
                "CMUX_SSH_RECONNECT_LIMIT": "1",
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "abc",
            ])
            #expect(run.finished, "\(name): the loop did not end")
            #expect(run.attempts == 2, "\(name): \(run.attempts) attempts for a limit of 1")
            #expect(run.sleeps == ["2"], "\(name): slept \(run.sleeps)")
            #expect(Self.notices(of: "CMUX_SSH_RECONNECT_DELAY_SECONDS=abc", in: run.stderr) == 1,
                    "\(name): \(run.stderr)")
        }
    }

    /// A delay too large to mean anything is held to the reconnect ceiling,
    /// `CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS`. macOS `sleep` rejects a value
    /// this long at once, so the loop used to retry with no wait.
    @Test func anOversizedDelayIsHeldToTheCeiling() throws {
        for (name, command) in try Self.startupCommands() {
            let run = try Self.run(command, environment: [
                "CMUX_SSH_RECONNECT_LIMIT": "1",
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "99999999999999999999",
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "1",
            ])
            #expect(run.finished, "\(name): the loop did not end")
            #expect(run.attempts == 2, "\(name): \(run.attempts) attempts for a limit of 1")
            #expect(run.sleeps == ["1"], "\(name): slept \(run.sleeps)")
        }
    }

    /// An oversized limit made `[ -ge ]` fail on every retry. It is read as the
    /// largest budget instead, said once, and never reaches the comparison.
    @Test func anOversizedLimitIsReadAsTheCeilingAndSaidOnce() throws {
        for (name, command) in try Self.startupCommands() {
            let run = try Self.run(command, environment: [
                "CMUX_SSH_RECONNECT_LIMIT": "99999999999999999999",
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "1",
            ], failingAttempts: 2)
            #expect(run.finished, "\(name): the loop did not end")
            #expect(run.attempts == 3, "\(name): \(run.attempts) attempts")
            #expect(run.sleeps == ["1", "1"], "\(name): slept \(run.sleeps)")
            #expect(!run.stderr.contains("integer expression expected"), "\(name): \(run.stderr)")
            #expect(Self.notices(of: "CMUX_SSH_RECONNECT_LIMIT=99999999999999999999", in: run.stderr) == 1,
                    "\(name): \(run.stderr)")
        }
    }

    /// Values that already worked keep working: a limit of 0 still means one
    /// attempt and no retry.
    @Test func aLimitOfZeroStillMeansNoRetry() throws {
        for (name, command) in try Self.startupCommands() {
            let run = try Self.run(command, environment: [
                "CMUX_SSH_RECONNECT_LIMIT": "0",
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "1",
            ])
            #expect(run.finished, "\(name): the loop did not end")
            #expect(run.attempts == 1, "\(name): \(run.attempts) attempts for a limit of 0")
            #expect(run.sleeps.isEmpty, "\(name): slept \(run.sleeps)")
            #expect(run.stderr.isEmpty, "\(name): \(run.stderr)")
        }
    }
}
