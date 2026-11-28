import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The tmux these tests run as the "remote" one; the suite is skipped without it.
private let remoteTmuxRenamedSessionLocalTmuxPath: String? = [
    "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
].first { FileManager.default.isExecutableFile(atPath: $0) }

/// `cmux ssh-tmux` mirrors every session the host listed, even one renamed between the
/// listing and the attach (https://github.com/manaflow-ai/cmux/issues/16103).
///
/// Discovery lists each session with its stable id (`$3`) and its name, and the mirror
/// attached by name. A tmux config that names sessions after the active window's title
/// renames a busy session several times a second, so the name could be gone by the time
/// `attach-session -t <name>` ran and that session was skipped without an error. These
/// tests drive the real controller through a stand-in `ssh` that runs each remote
/// command against a private local tmux server.
@MainActor
@Suite(.serialized, .enabled(if: remoteTmuxRenamedSessionLocalTmuxPath != nil))
struct RemoteTmuxAttachRenamedSessionTests {
    private let sshOverrideKey = "CMUX_REMOTE_TMUX_SSH_FOR_TESTING"

    @Test(.timeLimit(.minutes(2)))
    func aSessionRenamedAfterDiscoveryIsStillMirrored() async throws {
        try await withLocalTmuxHost(sessions: ["agent-working"]) { controller, host, windowId, tmux in
            // What discovery saw: the name and the stable id.
            let listed = try tmux(["list-sessions", "-F", "#{session_id} #{session_name}"])
            let rawId = try #require(listed.split(separator: " ").first.map(String.init), "no session: \(listed)")
            // The session renames itself before the attach runs.
            _ = try tmux(["rename-session", "-t", "=agent-working", "agent-done"])

            // The production handoff from discovery, which carries the listed id to the attach.
            let manager = try #require(AppDelegate.shared?.tabManagerFor(windowId: windowId))
            let mirrored = controller.mirrorDiscoveredSessions(
                host: host,
                sessions: [RemoteTmuxSession(
                    id: rawId, name: "agent-working", windowCount: 1, attached: false, createdUnix: nil
                )],
                into: manager
            )
            #expect(mirrored.count == 1)
            let connection = try #require(controller.connection(host: host, sessionName: "agent-working"))
            defer { controller.detach(host: host, sessionName: connection.sessionName) }

            let connected = await connection.waitUntilConnected()
            #expect(connected, "the renamed session was not attached: \(connection.sessionName)")
            // The mirror follows the session's current name once tmux reports it.
            let deadline = Date().addingTimeInterval(5)
            while connection.sessionName != "agent-done", Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(connection.sessionName == "agent-done")
        }
    }

    /// The first attach of a discovered session targets its id.
    @Test func theIdModeTargetsTheSessionId() {
        #expect(
            RemoteTmuxControlAttachMode.attachSessionID(3).tmuxArguments(sessionName: "work")
                == ["-CC", "attach-session", "-t", "$3"]
        )
    }

    private func withLocalTmuxHost(
        sessions: [String],
        _ body: @MainActor (
            RemoteTmuxController, RemoteTmuxHost, UUID, ([String]) throws -> String
        ) async throws -> Void
    ) async throws {
        let tmuxPath = try #require(remoteTmuxRenamedSessionLocalTmuxPath)
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
            let host = RemoteTmuxHost(destination: "renamed-session-\(UUID().uuidString)@example.test")
            defer {
                for name in sessions { controller.detach(host: host, sessionName: name) }
            }

            try await body(controller, host, windowId, tmux)
        }
    }
}
