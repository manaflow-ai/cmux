import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The tmux these tests run as the "remote" one; the suite is skipped without it.
private let remoteTmuxExactTargetLocalTmuxPath: String? = [
    "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
].first { FileManager.default.isExecutableFile(atPath: $0) }

/// ssh-tmux must reach a tmux session by its exact name, whatever the name looks like
/// (https://github.com/manaflow-ai/cmux/issues/21595).
///
/// tmux parses a `-t` target before it looks for a session: a name that starts with `@` is
/// read as a window id and one that starts with `%` as a pane id, and a bare name that
/// matches no session is tried as a prefix of another one. Only an `=` in front makes it an
/// exact session name. These tests drive the real controller through a stand-in `ssh` that
/// runs the remote command against a private local tmux server, so every tmux target the
/// attach sends is parsed by tmux itself.
@MainActor
@Suite(.serialized, .enabled(if: remoteTmuxExactTargetLocalTmuxPath != nil))
struct RemoteTmuxExactSessionTargetTests {
    private let sshOverrideKey = "CMUX_REMOTE_TMUX_SSH_FOR_TESTING"

    /// The report: the host's only session is named `@dev-vm`, and `cmux ssh-tmux <host>`
    /// failed with "could not mirror any tmux session".
    @Test(.timeLimit(.minutes(2)))
    func discoveryMirrorsASessionWhoseNameStartsWithAt() async throws {
        try await withLocalTmuxHost(sessions: ["@dev-vm"]) { controller, host, windowId, _ in
            let outcome = try await controller.attachHost(
                host: host, windowTarget: .explicitWindow(windowId), activate: false)
            guard case let .mirrored(_, workspaceIds) = outcome else {
                Issue.record("expected the session to be mirrored, got \(outcome)")
                return
            }
            #expect(workspaceIds.count == 1)
            #expect(controller.sessionMirror(host: host, sessionName: "@dev-vm") != nil)
        }
    }

    /// An attach to a named session (`remote.tmux.attach`) checks the session with
    /// `has-session` first, then opens the control stream; both must find `%build`.
    @Test(.timeLimit(.minutes(2)))
    func namedAttachReachesASessionWhoseNameStartsWithPercent() async throws {
        try await withLocalTmuxHost(sessions: ["%build"]) { controller, host, _, _ in
            let authArgv = try await controller.attachControlStreamWhenReady(
                host: host, sessionName: "%build")
            #expect(authArgv == nil)
            let connection = try #require(controller.connection(host: host, sessionName: "%build"))
            #expect(!connection.exited)
        }
    }

    /// A bare name is a prefix match once no session has exactly that name, so asking for
    /// `dev` attached to `devbox`. It must report that `dev` does not exist instead.
    @Test(.timeLimit(.minutes(2)))
    func namedAttachDoesNotPrefixMatchAnotherSession() async throws {
        try await withLocalTmuxHost(sessions: ["devbox"]) { controller, host, _, tmux in
            do {
                _ = try await controller.attachControlStreamWhenReady(host: host, sessionName: "dev")
                Issue.record("attaching to the missing session 'dev' succeeded")
            } catch let error as RemoteTmuxError {
                guard case .commandFailed = error else {
                    Issue.record("expected tmux's own failure for 'dev', got \(error)")
                    return
                }
            }
            let attached = controller.connection(host: host, sessionName: "dev")
            #expect(attached == nil || attached?.exited == true)
            #expect(try tmux(["list-clients", "-t", "=devbox", "-F", "#{client_name}"]).isEmpty,
                    "a control client attached to devbox")
        }
    }

    /// The beta multiplexer scopes each session through a channel, which checks a
    /// window reorder with `list-windows -t <session>` and pushes the session's identity
    /// with `set-environment -t <session>`. Without a session id yet, both fall back to
    /// the name, and `@dev` must still be read as that session, not as a window id.
    @Test(.timeLimit(.minutes(2)))
    func multiplexChannelTargetsASessionWhoseNameStartsWithAtByName() async throws {
        try await withLocalTmuxHost(sessions: ["@dev"]) { controller, host, _, tmux in
            _ = try await controller.attachControlStreamWhenReady(host: host, sessionName: "@dev")
            let connection = try #require(controller.connection(host: host, sessionName: "@dev"))
            let windowIds = try tmux(["list-windows", "-t", "=@dev", "-F", "#{window_id}"])
                .split(separator: "\n")
                .compactMap { Int($0.dropFirst()) }
            try #require(!windowIds.isEmpty)
            let channel = RemoteTmuxSessionChannel(
                underlying: connection, sessionName: "@dev", sessionId: nil, windowIds: windowIds)
            defer { channel.detach() }
            channel.sharedStream = connection

            let verified = await withCheckedContinuation { continuation in
                let sent = channel.sendWindowReorder(["refresh-client"]) { continuation.resume(returning: $0) }
                if !sent { continuation.resume(returning: false) }
            }
            #expect(verified, "the reorder check did not find the session @dev")

            channel.setMirrorEnvironment(["CMUX_EXACT_TARGET_PROBE": "1"])
            var pushed = ""
            for _ in 0..<50 {
                pushed = try tmux(["show-environment", "-t", "=@dev", "CMUX_EXACT_TARGET_PROBE"])
                if pushed == "CMUX_EXACT_TARGET_PROBE=1" { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(pushed == "CMUX_EXACT_TARGET_PROBE=1", "the identity push missed the session @dev")
        }
    }

    private func withLocalTmuxHost(
        sessions: [String],
        _ body: @MainActor (
            RemoteTmuxController, RemoteTmuxHost, UUID, ([String]) throws -> String
        ) async throws -> Void
    ) async throws {
        let tmuxPath = try #require(remoteTmuxExactTargetLocalTmuxPath)
        try await AppContextSerialGate.withExclusiveAppContext {
            // tmux keeps its socket under TMUX_TMPDIR, and a socket path has to stay short.
            let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("cmux-rt-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let tmuxDir = root.appendingPathComponent("t", isDirectory: true)
            try FileManager.default.createDirectory(at: tmuxDir, withIntermediateDirectories: true)
            let pathValue = "\((tmuxPath as NSString).deletingLastPathComponent):/usr/bin:/bin"

            func tmux(_ arguments: [String]) throws -> String {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tmuxPath)
                process.arguments = arguments
                process.environment = ["TMUX_TMPDIR": tmuxDir.path, "PATH": pathValue, "HOME": root.path]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = Pipe()
                process.standardInput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for name in sessions {
                _ = try tmux(["new-session", "-d", "-s", name, "-x", "80", "-y", "24"])
            }
            defer { _ = try? tmux(["kill-server"]) }
            let listed = try tmux(["list-sessions", "-F", "#{session_name}"])
            try #require(listed.split(separator: "\n").map(String.init).sorted() == sessions.sorted())

            // Stands in for ssh: control operations (`-O check`, `-O exit`) succeed, and
            // anything else runs its remote command (the last argument) locally. `-tt` asks
            // for a remote terminal, which `tmux -CC` needs, so that case runs under script(1).
            let sshURL = root.appendingPathComponent("ssh")
            try """
            #!/bin/sh
            for arg in "$@"; do
              [ "$arg" = "-O" ] && exit 0
            done
            tty=0
            for arg in "$@"; do
              [ "$arg" = "-tt" ] && tty=1
              command="$arg"
            done
            unset TMUX TMUX_PANE
            export TMUX_TMPDIR='\(tmuxDir.path)' PATH='\(pathValue)' HOME='\(root.path)'
            if [ "$tty" = 1 ]; then
              exec /usr/bin/script -q /dev/null /bin/sh -c "$command"
            fi
            exec /bin/sh -c "$command"
            """.write(to: sshURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sshURL.path)
            let previousSSH = getenv(sshOverrideKey).map { String(cString: $0) }
            setenv(sshOverrideKey, sshURL.path, 1)
            defer {
                if let previousSSH { setenv(sshOverrideKey, previousSSH, 1) } else { unsetenv(sshOverrideKey) }
            }

            let appDelegate = try #require(AppDelegate.shared)
            let controller = appDelegate.remoteTmuxController
            let windowId = appDelegate.createMainWindow(shouldActivate: false)
            defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId) }
            let host = RemoteTmuxHost(destination: "exact-target-\(UUID().uuidString)@example.test")
            defer {
                for name in sessions { controller.detach(host: host, sessionName: name) }
            }

            try await body(controller, host, windowId, tmux)
        }
    }
}
