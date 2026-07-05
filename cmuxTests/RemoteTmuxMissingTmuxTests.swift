import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for friendly `cmux ssh-tmux` failures when the remote
/// host has no tmux installed (https://github.com/manaflow-ai/cmux/issues/7368).
@Suite struct RemoteTmuxMissingTmuxTests {
    @Test(arguments: [
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "cmux-remote-tmux: line 0: exec: tmux: not found"),
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "cmux-remote-tmux: 1: exec: tmux: not found"),
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "cmux-remote-tmux: tmux not found"),
    ])
    func listSessionsReportsActionableTmuxMissing(shape: RemoteTmuxCommandFailureShape) async throws {
        let env = try FakeSSHEnvironment(exitCode: shape.exitCode, stderr: shape.stderr)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        do {
            _ = try await transport.listSessions()
            Issue.record("Expected listSessions to fail when tmux is missing")
        } catch let error as RemoteTmuxError {
            let message = error.message
            #expect(message.contains("tmux was not found on user@host"))
            #expect(message.contains(RemoteTmuxVersion.minimumSupported.displayString))
            #expect(message.contains("brew install tmux"))
            #expect(!message.contains("exit 127"))
        } catch {
            Issue.record("Expected RemoteTmuxError, got \(error)")
        }
    }

    @Test func resolverCommandContainsMissingTmuxText() {
        let command = RemoteTmuxHost.tmuxRemoteCommand(arguments: ["-V"])

        #expect(command.contains("tmux not found"))
    }

    @Test func noServerStillReportsEmptySessions() async throws {
        let env = try FakeSSHEnvironment(exitCode: 1, stderr: "no server running on /tmp/tmux-501/default")
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let sessions = try await transport.listSessions()

        #expect(sessions.isEmpty)
    }

    @Test func authFailureStillPreservesCommandFailedForInteractiveRetry() async throws {
        let stderr = "user@host: Permission denied (publickey,password)."
        let env = try FakeSSHEnvironment(exitCode: 255, stderr: stderr)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        do {
            _ = try await transport.listSessions()
            Issue.record("Expected listSessions to fail for SSH auth failure")
        } catch let error as RemoteTmuxError {
            guard case let .commandFailed(exitCode, capturedStderr) = error else {
                Issue.record("Expected commandFailed, got \(error)")
                return
            }
            #expect(exitCode == 255)
            #expect(capturedStderr == stderr + "\n")
            #expect(RemoteTmuxSSHTransport.indicatesAuthRequired(capturedStderr))
        } catch {
            Issue.record("Expected RemoteTmuxError, got \(error)")
        }
    }

}

struct RemoteTmuxCommandFailureShape: Sendable {
    let exitCode: Int32
    let stderr: String
}

/// A throwaway local `ssh` replacement that returns one configured result.
private struct FakeSSHEnvironment {
    let root: URL
    let executablePath: String

    init(exitCode: Int32, stderr: String) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let script = """
        #!/bin/sh
        printf '%s\\n' \(Self.shellSingleQuoted(stderr)) >&2
        exit \(exitCode)
        """
        let scriptURL = root.appendingPathComponent("ssh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        executablePath = scriptURL.path
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Post-fix classifier coverage (compiles only with the fix)

@Suite struct RemoteTmuxMissingTmuxPostFixTests {
    @Test(arguments: [
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "cmux-remote-tmux: line 0: exec: tmux: not found"),
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "cmux-remote-tmux: 1: exec: tmux: not found"),
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "cmux-remote-tmux: tmux not found"),
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "bash: tmux: command not found"),
    ])
    func classifiesMissingTmux(shape: RemoteTmuxCommandFailureShape) {
        #expect(RemoteTmuxSSHTransport.indicatesTmuxMissing(exitCode: shape.exitCode, stderr: shape.stderr))
    }

    @Test(arguments: [
        RemoteTmuxCommandFailureShape(exitCode: 0, stderr: "cmux-remote-tmux: tmux not found"),
        RemoteTmuxCommandFailureShape(exitCode: 1, stderr: "cmux-remote-tmux: tmux not found"),
        RemoteTmuxCommandFailureShape(exitCode: 1, stderr: "no server running on /tmp/tmux-501/default"),
        RemoteTmuxCommandFailureShape(exitCode: 255, stderr: "Permission denied (publickey)"),
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "Permission denied (publickey)"),
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: ""),
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "cmux-remote-tmux: line 0: exec: htop: not found"),
    ])
    func doesNotClassifyUnrelatedFailuresAsMissingTmux(shape: RemoteTmuxCommandFailureShape) {
        #expect(!RemoteTmuxSSHTransport.indicatesTmuxMissing(exitCode: shape.exitCode, stderr: shape.stderr))
    }

    @Test func tmuxNotFoundMessageIsActionableAndSanitized() {
        let message = RemoteTmuxError.tmuxNotFound(destination: "user@host").message

        #expect(message.contains("tmux was not found on user@host"))
        #expect(message.contains(RemoteTmuxVersion.minimumSupported.displayString))
        #expect(message.contains("brew install tmux"))

        let sanitized = RemoteTmuxError.tmuxNotFound(destination: "user@host\u{1b}[31m").message
        #expect(!sanitized.contains("\u{1b}"))
        #expect(sanitized.contains("user@host [31m"))
    }

    @Test func resolverSentinelAndClassifierStayInSync() {
        let command = RemoteTmuxHost.tmuxRemoteCommand(arguments: [])

        #expect(command.contains(RemoteTmuxHost.tmuxNotFoundSentinel))
        #expect(RemoteTmuxSSHTransport.indicatesTmuxMissing(
            exitCode: 127,
            stderr: RemoteTmuxHost.tmuxNotFoundSentinel
        ))
    }
}
