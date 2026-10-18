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
/// rejects, including one too long for it, made the loop retry with no wait. Each test runs the startup command the app really builds under `/bin/sh`,
/// with a stand-in cmux CLI whose attach always fails as retryable (255).
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
        let elapsed: TimeInterval
        let stderr: String
        let finished: Bool
    }

    /// Runs `command` with the given reconnect settings, stopping it after `deadline`.
    private static func run(_ command: String, environment extra: [String: String], deadline: TimeInterval) throws -> LoopRun {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("freestyle-reconnect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = root.appendingPathComponent("calls")
        let cli = root.appendingPathComponent("cmux")
        try "#!/bin/sh\necho attach >> '\(calls.path)'\nexit 255\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
            "PATH": "/usr/bin:/bin",
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
            // Whatever the loop is sleeping in, then the loop.
            let children = Process()
            children.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            children.arguments = ["-KILL", "-P", String(process.processIdentifier)]
            try? children.run()
            children.waitUntilExit()
            process.terminate()
            process.waitUntilExit()
        }
        let elapsed = Date().timeIntervalSince(started)
        let attempts = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return LoopRun(attempts: attempts, elapsed: elapsed, stderr: stderr, finished: finished)
    }

    /// `sleep` rejects `abc` at once, so the loop retried without waiting. It must
    /// wait the default 2 seconds instead.
    @Test func aDelaySleepCannotReadIsReplacedByTheDefaultWait() throws {
        for (name, command) in try Self.startupCommands() {
            let run = try Self.run(command, environment: [
                "CMUX_SSH_RECONNECT_LIMIT": "1",
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "abc",
            ], deadline: 10)
            #expect(run.finished, "\(name): the loop did not end")
            #expect(run.attempts == 2, "\(name): \(run.attempts) attempts for a limit of 1")
            #expect(run.elapsed >= 1.5, "\(name): retried after \(run.elapsed)s, without waiting")
            #expect(!run.stderr.contains("sleep:"), "\(name): \(run.stderr)")
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
            ], deadline: 10)
            #expect(run.finished, "\(name): the loop was still sleeping after 10s")
            #expect(run.attempts == 2, "\(name): \(run.attempts) attempts for a limit of 1")
            #expect(run.elapsed >= 0.8, "\(name): retried after \(run.elapsed)s, not the 1s cap")
            #expect(!run.stderr.contains("sleep:"), "\(name): \(run.stderr)")
        }
    }

    /// An oversized limit made `[ -ge ]` fail on every retry. It is read as the
    /// largest budget instead, said once, and never reaches the comparison.
    @Test func anOversizedLimitIsReadAsTheCeilingAndSaidOnce() throws {
        for (name, command) in try Self.startupCommands() {
            let run = try Self.run(command, environment: [
                "CMUX_SSH_RECONNECT_LIMIT": "99999999999999999999",
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "1",
            ], deadline: 2.5)
            #expect(run.attempts >= 2, "\(name): \(run.attempts) attempts")
            #expect(!run.stderr.contains("integer expression expected"), "\(name): \(run.stderr)")
            let notices = run.stderr.components(separatedBy: "CMUX_SSH_RECONNECT_LIMIT=99999999999999999999").count - 1
            #expect(notices == 1, "\(name): \(run.stderr)")
        }
    }

    /// Values that already worked keep working: a limit of 0 still means one
    /// attempt and no retry.
    @Test func aLimitOfZeroStillMeansNoRetry() throws {
        for (name, command) in try Self.startupCommands() {
            let run = try Self.run(command, environment: [
                "CMUX_SSH_RECONNECT_LIMIT": "0",
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "1",
            ], deadline: 10)
            #expect(run.finished, "\(name): the loop did not end")
            #expect(run.attempts == 1, "\(name): \(run.attempts) attempts for a limit of 0")
            #expect(run.stderr.isEmpty, "\(name): \(run.stderr)")
        }
    }
}
