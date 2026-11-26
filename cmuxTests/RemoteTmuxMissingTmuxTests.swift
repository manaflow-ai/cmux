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
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "bash: tmux: command not found"),
        RemoteTmuxCommandFailureShape(exitCode: 127, stderr: "sh: 1: tmux: not found"),
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

    @Test func resolverExecutesMissingTmuxBranchAndFoundPathControl() throws {
        let root = try temporaryDirectory(prefix: "remote-tmux-resolver")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let emptyPath = root.appendingPathComponent("emptypath", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyPath, withIntermediateDirectories: true)

        let command = RemoteTmuxHost.tmuxRemoteCommand(arguments: ["-V"])
        let transformed = try fakeRootedTmuxCommand(command, root: root)
        let environment = ["HOME": home.path, "PATH": emptyPath.path]

        let missing = try runShell(transformed, environment: environment)

        #expect(missing.status == 127, Comment(rawValue: missing.stderr))
        #expect(missing.stdout == "")
        #expect(missing.stderr == "cmux-remote-tmux: tmux not found\n")

        let shim = URL(fileURLWithPath: root.path + "/opt/homebrew/bin/tmux")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(
            at: shim,
            contents: """
            #!/bin/sh
            printf 'shim-tmux'
            for arg in "$@"; do printf ' <%s>' "$arg"; done
            printf '\\n'
            """
        )

        let found = try runShell(transformed, environment: environment)

        #expect(found.status == 0, Comment(rawValue: found.stderr))
        #expect(found.stdout == "shim-tmux <-V>\n")
        #expect(found.stderr == "")
    }

    @Test func discoverMirrorSessionsSurfacesActionableTmuxMissing() async throws {
        let stderr = "cmux-remote-tmux: line 0: exec: tmux: not found"
        let env = try FakeSSHEnvironment(exitCode: 127, stderr: stderr)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        do {
            _ = try await transport.discoverMirrorSessions(createIfEmpty: true)
            Issue.record("Expected discoverMirrorSessions to fail when tmux is missing")
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

    private func fakeRootedTmuxCommand(_ command: String, root: URL) throws -> String {
        let absoluteDirs = " /opt/homebrew/bin /usr/local/bin /opt/local/bin /usr/pkg/bin /snap/bin /usr/bin /bin; do"
        let rootDirs = [
            "opt/homebrew/bin",
            "usr/local/bin",
            "opt/local/bin",
            "usr/pkg/bin",
            "snap/bin",
            "usr/bin",
            "bin",
        ].map { root.path + "/" + $0 }.joined(separator: " ")
        let dirCount = command.components(separatedBy: absoluteDirs).count - 1
        try #require(dirCount == 1, "remote tmux resolver probe list drifted")
        var transformed = command.replacingOccurrences(of: absoluteDirs, with: " \(rootDirs); do")
        try #require(!transformed.contains(absoluteDirs), "remote tmux resolver still references real probe dirs")

        let pathHelper = "/usr/libexec/path_helper"
        let pathHelperCount = transformed.components(separatedBy: pathHelper).count - 1
        try #require(pathHelperCount == 2, "remote tmux resolver path_helper probes drifted")
        let rootedPathHelper = root.path + pathHelper
        transformed = transformed.replacingOccurrences(
            of: pathHelper,
            with: rootedPathHelper
        )
        let unrootedPathHelperRemainder = transformed.replacingOccurrences(of: rootedPathHelper, with: "")
        try #require(
            !unrootedPathHelperRemainder.contains(pathHelper),
            "remote tmux resolver still references real path_helper"
        )
        return transformed
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runShell(
        _ command: String,
        environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
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

    @Test func resolverSentinelMatchesClassifier() {
        #expect(RemoteTmuxHost.tmuxNotFoundSentinel == "cmux-remote-tmux: tmux not found")
        #expect(RemoteTmuxSSHTransport.indicatesTmuxMissing(
            exitCode: 127,
            stderr: RemoteTmuxHost.tmuxNotFoundSentinel
        ))
    }
}
