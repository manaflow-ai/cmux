import Darwin
import Combine
import XCTest
import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import CmuxSidebar
import CmuxRemoteWorkspace
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Closure shape shared by the scripted process-runner tests; mirrors the
/// legacy `runProcessOverrideForTesting` static signature so the scripted
/// bodies stay byte-identical.
private typealias RemoteProcessScript = (_ executable: String, _ arguments: [String], _ stdin: Data?, _ timeout: TimeInterval) throws -> (status: Int32, stdout: String, stderr: String)

/// Test fake for the coordinator's injected process-runner seam: scripts each
/// subprocess invocation. `@unchecked Sendable` because the scripts capture
/// test-local locks/semaphores exactly like the legacy static override did.
private struct ScriptedRemoteProcessRunner: RemoteSessionProcessRunning, @unchecked Sendable {
    let script: RemoteProcessScript

    func run(_ request: RemoteProcessRequest, operation: (any RemoteTransferCancelling)?) throws -> RemoteCommandResult {
        let result = try script(request.executable, request.arguments, request.stdin, request.timeout)
        return RemoteCommandResult(status: result.status, stdout: result.stdout, stderr: result.stderr)
    }
}

private func remoteDaemonServeCommand(_ command: String) -> Bool {
    command.contains("serve") && command.contains("--stdio")
}

private func remoteReverseRelayControlOperation(from arguments: [String]) -> (command: String, spec: String)? {
    guard let operationIndex = arguments.firstIndex(of: "-O"),
          operationIndex + 1 < arguments.count,
          let reverseIndex = arguments.firstIndex(of: "-R"),
          reverseIndex + 1 < arguments.count else {
        return nil
    }
    return (arguments[operationIndex + 1], arguments[reverseIndex + 1])
}

final class WorkspaceRemoteConnectionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32, stdout: String, stderr: String
        let timedOut: Bool
    }

    private func runProcess(executablePath: String, arguments: [String], timeout: TimeInterval) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                status: -1,
                stdout: "",
                stderr: String(describing: error),
                timedOut: false
            )
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private func writeShellFile(at url: URL, lines: [String]) throws {
        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeExecutableShellFile(at url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runRelayZshHistfile(
        configureUserHome: (URL) throws -> URL
    ) throws -> String {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-zsh-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay/64011.shell")

        try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let effectiveUserZdotdir = try configureUserHome(home)
        let bootstrap = RemoteRelayZshBootstrap(shellStateDir: relayDir.path)

        try writeShellFile(at: relayDir.appendingPathComponent(".zshenv"), lines: bootstrap.zshEnvLines)
        try writeShellFile(at: relayDir.appendingPathComponent(".zprofile"), lines: bootstrap.zshProfileLines)
        try writeShellFile(at: relayDir.appendingPathComponent(".zshrc"), lines: bootstrap.zshRCLines(commonShellLines: []))
        try writeShellFile(at: relayDir.appendingPathComponent(".zlogin"), lines: bootstrap.zshLoginLines)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "TERM=xterm-256color",
                "SHELL=/bin/zsh",
                "USER=\(NSUserName())",
                "CMUX_REAL_ZDOTDIR=\(home.path)",
                "ZDOTDIR=\(relayDir.path)",
                "/bin/zsh",
                "-ilc",
                "print -r -- \"$HISTFILE\"",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let histfile = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        XCTAssertEqual(histfile, effectiveUserZdotdir.appendingPathComponent(".zsh_history").path)
        return histfile ?? ""
    }

    private func runGeneratedBashBootstrapMarkers(startupFiles: [String: String]) throws -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-bash-\(UUID().uuidString)")
        let bin = home.appendingPathComponent("bin")
        let markerFile = home.appendingPathComponent("markers.txt")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        for (fileName, marker) in startupFiles {
            let startupScript = """
            printf '%s\\n' '\(marker)' >> "$CMUX_BASH_MARKERS"
            """
            try startupScript.write(to: home.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        }
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("bash"),
            body: """
            #!/bin/sh
            rcfile=
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --rcfile)
                  shift
                  rcfile="${1:-}"
                  ;;
              esac
              shift || true
            done
            if [ -n "$rcfile" ]; then
              . "$rcfile"
            fi
            """
        )

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: ""
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "SHELL=\(bin.appendingPathComponent("bash").path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "TERM=xterm-256color",
                "USER=\(NSUserName())",
                "CMUX_BASH_MARKERS=\(markerFile.path)",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let contents = (try? String(contentsOf: markerFile, encoding: .utf8)) ?? ""
        return contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func testGeneratedBashBootstrapSourcesLoginFilesInBashPrecedenceOrder() throws {
        XCTAssertEqual(
            try runGeneratedBashBootstrapMarkers(startupFiles: [
                ".bash_profile": "bash_profile",
                ".bash_login": "bash_login",
                ".profile": "profile",
                ".bashrc": "bashrc",
            ]),
            ["bash_profile", "bashrc"]
        )
        XCTAssertEqual(
            try runGeneratedBashBootstrapMarkers(startupFiles: [
                ".bash_login": "bash_login",
                ".profile": "profile",
                ".bashrc": "bashrc",
            ]),
            ["bash_login", "bashrc"]
        )
        XCTAssertEqual(
            try runGeneratedBashBootstrapMarkers(startupFiles: [
                ".profile": "profile",
                ".bashrc": "bashrc",
            ]),
            ["profile", "bashrc"]
        )
    }

    func testGeneratedFallbackShellBootstrapPrependsCmuxBinOnce() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fallback-shell-bootstrap-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let capturedPath = root.appendingPathComponent("path.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("fish"),
            body: """
            #!/bin/sh
            printf '%s\\n' "$PATH" > "$CMUX_CAPTURE_PATH"
            """
        )

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: ""
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "SHELL=\(bin.appendingPathComponent("fish").path)",
                "PATH=/usr/bin:/bin",
                "TERM=xterm-256color",
                "USER=\(NSUserName())",
                "CMUX_CAPTURE_PATH=\(capturedPath.path)",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let path = try String(contentsOf: capturedPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cmuxBinEntries = path.split(separator: ":")
            .filter { $0 == "\(home.path)/.cmux/bin" }
        XCTAssertEqual(cmuxBinEntries.count, 1, path)
    }

    func testRemoteRelayMetadataCleanupScriptRemovesMatchingSocketAddr() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-cleanup-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let socketAddrURL = home.appendingPathComponent(".cmux/socket_addr")
        let authURL = relayDir.appendingPathComponent("64008.auth")
        let daemonPathURL = relayDir.appendingPathComponent("64008.daemon_path")
        let slotURL = relayDir.appendingPathComponent("64008.slot")
        let ttyURL = relayDir.appendingPathComponent("64008.tty")

        XCTAssertNoThrow(try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try "127.0.0.1:64008".write(to: socketAddrURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "auth".write(to: authURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "daemon".write(to: daemonPathURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "slot".write(to: slotURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "ttys001".write(to: ttyURL, atomically: true, encoding: .utf8))
        defer { try? fileManager.removeItem(at: home) }

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "/bin/sh",
                "-c",
                RemoteSessionCoordinator.remoteRelayMetadataCleanupScript(relayPort: 64008),
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(fileManager.fileExists(atPath: socketAddrURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: authURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: daemonPathURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: slotURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: ttyURL.path))
    }

    func testRemoteRelayMetadataCleanupScriptPreservesDifferentSocketAddr() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-cleanup-preserve-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let socketAddrURL = home.appendingPathComponent(".cmux/socket_addr")
        let authURL = relayDir.appendingPathComponent("64009.auth")
        let daemonPathURL = relayDir.appendingPathComponent("64009.daemon_path")
        let slotURL = relayDir.appendingPathComponent("64009.slot")
        let ttyURL = relayDir.appendingPathComponent("64009.tty")

        XCTAssertNoThrow(try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try "127.0.0.1:64010".write(to: socketAddrURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "auth".write(to: authURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "daemon".write(to: daemonPathURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "slot".write(to: slotURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "ttys002".write(to: ttyURL, atomically: true, encoding: .utf8))
        defer { try? fileManager.removeItem(at: home) }

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "/bin/sh",
                "-c",
                RemoteSessionCoordinator.remoteRelayMetadataCleanupScript(relayPort: 64009),
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(fileManager.fileExists(atPath: socketAddrURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: authURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: daemonPathURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: slotURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: ttyURL.path))
    }

    func testRemoteStaleRelayListenerCleanupScriptKillsMatchingPersistentRelayListener() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-stale-relay-cleanup-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let killLog = root.appendingPathComponent("kill.log")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try "".write(to: killLog, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            p33681
            f12
            n127.0.0.1:50446
            EOF
            """
        )
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            33681 1 /usr/sbin/sshd-session
            34057 33681 /Users/cmux/.cmux/bin/cmuxd-remote/current/darwin-arm64/cmuxd-remote serve --stdio --persistent --slot ssh-c4ba8ab1
            34058 33681 /bin/zsh
            EOF
            """
        )

        let script = try XCTUnwrap(
            RemoteSessionCoordinator.remoteStaleRelayListenerCleanupScript(
                relayPort: 50446,
                persistentDaemonSlot: "ssh-c4ba8ab1"
            )
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "PATH=\(bin.path):/usr/bin:/bin",
                "CMUX_KILL_LOG=\(killLog.path)",
                "/bin/sh",
                "-c",
                """
                kill() { printf '%s\\n' "$*" >> "$CMUX_KILL_LOG"; return 0; }
                \(script)
                """,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("cmux_stale_relay_killed pid=33681 children=34057 port=50446"), result.stdout)

        let killOutput = try String(contentsOf: killLog, encoding: .utf8)
        XCTAssertTrue(killOutput.contains("-TERM 33681 34057"), killOutput)
        XCTAssertTrue(killOutput.contains("-KILL 33681"), killOutput)
        XCTAssertTrue(killOutput.contains("-KILL 34057"), killOutput)
    }

    func testRemoteStaleRelayListenerCleanupScriptPreservesDifferentPersistentSlot() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-stale-relay-preserve-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let killLog = root.appendingPathComponent("kill.log")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try "".write(to: killLog, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            p33681
            f12
            n127.0.0.1:50446
            EOF
            """
        )
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            33681 1 /usr/sbin/sshd-session
            34057 33681 /Users/cmux/.cmux/bin/cmuxd-remote/current/darwin-arm64/cmuxd-remote serve --stdio --persistent --slot ssh-other
            EOF
            """
        )

        let script = try XCTUnwrap(
            RemoteSessionCoordinator.remoteStaleRelayListenerCleanupScript(
                relayPort: 50446,
                persistentDaemonSlot: "ssh-c4ba8ab1"
            )
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "PATH=\(bin.path):/usr/bin:/bin",
                "CMUX_KILL_LOG=\(killLog.path)",
                "/bin/sh",
                "-c",
                """
                kill() { printf '%s\\n' "$*" >> "$CMUX_KILL_LOG"; return 0; }
                \(script)
                """,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(try String(contentsOf: killLog, encoding: .utf8), "")
    }

    func testRemoteStaleRelayListenerCleanupScriptMatchesPersistentSlotExactly() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-stale-relay-slot-prefix-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let killLog = root.appendingPathComponent("kill.log")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try "".write(to: killLog, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            p33681
            f12
            n127.0.0.1:50446
            EOF
            """
        )
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            33681 1 /usr/sbin/sshd-session
            34057 33681 /Users/cmux/.cmux/bin/cmuxd-remote/current/darwin-arm64/cmuxd-remote serve --stdio --persistent --slot ssh-ab
            EOF
            """
        )

        let script = try XCTUnwrap(
            RemoteSessionCoordinator.remoteStaleRelayListenerCleanupScript(
                relayPort: 50446,
                persistentDaemonSlot: "ssh-a"
            )
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "PATH=\(bin.path):/usr/bin:/bin",
                "CMUX_KILL_LOG=\(killLog.path)",
                "/bin/sh",
                "-c",
                """
                kill() { printf '%s\\n' "$*" >> "$CMUX_KILL_LOG"; return 0; }
                \(script)
                """,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(try String(contentsOf: killLog, encoding: .utf8), "")
    }

    func testRemoteStaleRelayListenerCleanupScriptKillsMetadataMatchedListenerWithoutChild() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-stale-relay-metadata-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let relayDir = root.appendingPathComponent(".cmux/relay")
        let killLog = root.appendingPathComponent("kill.log")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true)
        try "/Users/cmux/.cmux/bin/cmuxd-remote/current/darwin-arm64/cmuxd-remote".write(
            to: relayDir.appendingPathComponent("50446.daemon_path"),
            atomically: true,
            encoding: .utf8
        )
        try "ssh-c4ba8ab1".write(
            to: relayDir.appendingPathComponent("50446.slot"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(to: killLog, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            p33681
            f12
            n127.0.0.1:50446
            EOF
            """
        )
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            33681 1 /usr/sbin/sshd-session
            EOF
            """
        )

        let script = try XCTUnwrap(
            RemoteSessionCoordinator.remoteStaleRelayListenerCleanupScript(
                relayPort: 50446,
                persistentDaemonSlot: "ssh-c4ba8ab1"
            )
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(root.path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "CMUX_KILL_LOG=\(killLog.path)",
                "/bin/sh",
                "-c",
                """
                kill() { printf '%s\\n' "$*" >> "$CMUX_KILL_LOG"; return 0; }
                \(script)
                """,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(
            result.stdout.contains("cmux_stale_relay_killed pid=33681 children= port=50446 reason=metadata"),
            result.stdout
        )

        let killOutput = try String(contentsOf: killLog, encoding: .utf8)
        XCTAssertTrue(killOutput.contains("-TERM 33681"), killOutput)
        XCTAssertTrue(killOutput.contains("-KILL 33681"), killOutput)
    }

    func testRemoteStaleRelayListenerCleanupScriptPreservesMetadataMatchedDifferentPersistentSlot() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-stale-relay-metadata-preserve-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let relayDir = root.appendingPathComponent(".cmux/relay")
        let killLog = root.appendingPathComponent("kill.log")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true)
        try "/Users/cmux/.cmux/bin/cmuxd-remote/current/darwin-arm64/cmuxd-remote".write(
            to: relayDir.appendingPathComponent("50446.daemon_path"),
            atomically: true,
            encoding: .utf8
        )
        try "ssh-other-slot".write(
            to: relayDir.appendingPathComponent("50446.slot"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(to: killLog, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            p33681
            f12
            n127.0.0.1:50446
            EOF
            """
        )
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            33681 1 /usr/sbin/sshd-session
            EOF
            """
        )

        let script = try XCTUnwrap(
            RemoteSessionCoordinator.remoteStaleRelayListenerCleanupScript(
                relayPort: 50446,
                persistentDaemonSlot: "ssh-c4ba8ab1"
            )
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(root.path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "CMUX_KILL_LOG=\(killLog.path)",
                "/bin/sh",
                "-c",
                """
                kill() { printf '%s\\n' "$*" >> "$CMUX_KILL_LOG"; return 0; }
                \(script)
                """,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(try String(contentsOf: killLog, encoding: .utf8), "")
    }

    func testRelayZshBootstrapUsesRealHomeHistoryByDefault() throws {
        let histfile = try runRelayZshHistfile { home in
            try ":\n".write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            try ":\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return home
        }

        XCTAssertTrue(histfile.hasSuffix("/.zsh_history"))
    }

    func testRelayZshBootstrapUsesUserUpdatedZdotdirHistory() throws {
        let histfile = try runRelayZshHistfile { home in
            let altZdotdir = home.appendingPathComponent("dotfiles")
            try FileManager.default.createDirectory(at: altZdotdir, withIntermediateDirectories: true)
            try "export ZDOTDIR=\"$HOME/dotfiles\"\n".write(
                to: home.appendingPathComponent(".zshenv"),
                atomically: true,
                encoding: .utf8
            )
            try ":\n".write(to: altZdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return altZdotdir
        }

        XCTAssertTrue(histfile.contains("/dotfiles/.zsh_history"))
    }

    func testRemoteUTF8LocaleSetupLinesSeedUTF8LocaleWhenMissing() {
        let script = (RemoteShellEnvironment.utf8LocaleSetupLines() + [
            #"printf '%s' "${LANG}|${LC_CTYPE}|${LC_ALL}""#,
        ])
            .joined(separator: "\n")

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "LANG=",
                "LC_CTYPE=",
                "LC_ALL=",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "C.UTF-8|C.UTF-8|C.UTF-8")
    }

    func testRemoteUTF8LocaleSetupLinesPreserveExistingUTF8Locale() {
        let script = (RemoteShellEnvironment.utf8LocaleSetupLines() + [
            #"printf '%s' "${LANG}|${LC_CTYPE}|${LC_ALL}""#,
        ])
            .joined(separator: "\n")

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "LANG=ja_JP.UTF-8",
                "LC_CTYPE=",
                "LC_ALL=",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ja_JP.UTF-8||")
    }

    func testDaemonSocketForwardArgumentsTargetBakedVMSocket() {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlPath /tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            skipDaemonBootstrap: true
        )

        let arguments = configuration.daemonSocketForwardArguments(
            localPort: 64123,
            remoteSocketPath: "/run/cmuxd-remote.sock"
        )

        XCTAssertEqual(Array(arguments.prefix(4)), ["-N", "-T", "-S", "none"])
        XCTAssertTrue(arguments.contains("-p"))
        XCTAssertTrue(arguments.contains("2222"))
        XCTAssertTrue(arguments.contains("-i"))
        XCTAssertTrue(arguments.contains("/Users/test/.ssh/id_ed25519"))
        XCTAssertTrue(arguments.contains("127.0.0.1:64123:/run/cmuxd-remote.sock"))
        XCTAssertEqual(arguments.last, "cmux-macmini")
    }

    func testProxyBrokerTransportKeySeparatesVMBakedSSHFromStandardSSH() {
        let standard = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: ["ControlPath /tmp/cmux-ssh-%C"],
            localProxyPort: nil,
            relayPort: 64099,
            relayID: "relay-a",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let vmSSH = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: ["ControlPath /tmp/cmux-ssh-%C"],
            localProxyPort: nil,
            relayPort: 64099,
            relayID: "relay-a",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            skipDaemonBootstrap: true
        )
        let persistentPTYSSH = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: ["ControlPath /tmp/cmux-ssh-%C"],
            localProxyPort: nil,
            relayPort: 64099,
            relayID: "relay-a",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        let vmWebSocket = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:abcd1234",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "cmux vm-pty-attach --id abcd1234",
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "wss://sandbox.example/rpc",
                headers: ["e2b-traffic-access-token": "header-a"],
                token: "token-a",
                sessionId: "sess-a",
                expiresAtUnix: 1_800_000_000
            ),
            skipDaemonBootstrap: true
        )
        let vmWebSocketRefreshed = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:abcd1234",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "cmux vm-pty-attach --id abcd1234",
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "wss://sandbox.example/rpc",
                headers: ["e2b-traffic-access-token": "header-b"],
                token: "token-b",
                sessionId: "sess-b",
                expiresAtUnix: 1_800_000_100
            ),
            skipDaemonBootstrap: true
        )

        XCTAssertNotEqual(standard.proxyBrokerTransportKey, vmSSH.proxyBrokerTransportKey)
        XCTAssertNotEqual(standard.proxyBrokerTransportKey, persistentPTYSSH.proxyBrokerTransportKey)
        XCTAssertNotEqual(vmSSH.proxyBrokerTransportKey, vmWebSocket.proxyBrokerTransportKey)
        XCTAssertNotEqual(vmWebSocket.proxyBrokerTransportKey, vmWebSocketRefreshed.proxyBrokerTransportKey)
    }

    @MainActor
    func testWebSocketVMWithoutDaemonEndpointSkipsProxyStartup() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:test-no-daemon",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "cmux vm-pty-attach --id test-no-daemon",
            skipDaemonBootstrap: true
        )

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertNil(workspace.remoteProxyEndpoint)
    }

    @MainActor
    func testSkipBootstrapPersistentPTYDoesNotFailBakedCapabilityPreflight() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:test-persistent-no-daemon",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true
        )

        workspace.configureRemoteConnection(config, autoConnect: true)
        let deadline = Date().addingTimeInterval(0.5)
        while workspace.remoteConnectionState == .connecting && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertNil(workspace.remoteProxyEndpoint)
        let daemon = workspace.remoteStatusPayload()["daemon"] as? [String: Any]
        XCTAssertFalse((daemon?["detail"] as? String)?.contains("pty.session") == true)
    }

    func testRemoteDaemonCapabilityErrorsUseUserFacingMessage() {
        let message = RemoteDaemonStrings.appLocalized.missingRequiredCapabilitiesMessage([
            "pty.session",
            "pty.session.token",
        ])

        XCTAssertEqual(
            message,
            "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
        )
        XCTAssertFalse(message.contains("pty.session"))

        let notificationMessage = RemoteDaemonStrings.appLocalized.missingRequiredCapabilitiesMessage([
            "pty.write.notification",
        ])
        XCTAssertEqual(notificationMessage, message)
        XCTAssertFalse(notificationMessage.contains("pty.write.notification"))

        let rawError = NSError(domain: "cmux.remote.daemon", code: 43, userInfo: [
            NSLocalizedDescriptionKey: "remote daemon missing required capability pty.write.notification",
        ])
        let bootstrapMessage = RemoteSessionCoordinator.userFacingRemoteDaemonBootstrapErrorMessage(
            rawError,
            strings: .appLocalized
        )
        XCTAssertEqual(bootstrapMessage, message)
        XCTAssertFalse(bootstrapMessage.contains("pty.session"))
        XCTAssertFalse(bootstrapMessage.contains("pty.write.notification"))
    }

    @MainActor
    func testWebSocketVMWithDaemonEndpointStartsProxyCapableConnection() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:test-with-daemon",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "cmux vm-pty-attach --id test-with-daemon",
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "ws://127.0.0.1:65534/rpc",
                headers: [:],
                token: "token-a",
                sessionId: "sess-a",
                expiresAtUnix: 1_800_000_000
            ),
            skipDaemonBootstrap: true
        )

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(workspace.remoteConnectionState, .connecting)
        workspace.disconnectRemoteConnection(clearConfiguration: true)
    }

    func testReverseRelayStartupFailureDetailCapturesImmediateForwardingFailure() throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo 'remote port forwarding failed for listen port 64009' >&2; exit 1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()

        let detail = RemoteSessionCoordinator.reverseRelayStartupFailureDetail(
            process: process,
            stderrPipe: stderrPipe,
            gracePeriod: 1.0
        )

        XCTAssertEqual(detail, "remote port forwarding failed for listen port 64009")
    }

    func testExecutableSearchPathsIncludesHomebrewAndHomeFallbacks() {
        let paths = RemoteSessionCoordinator.executableSearchPaths(
            environment: [
                "HOME": "/Users/tester",
                "PATH": "/usr/bin:/bin",
            ],
            pathHelperOutput: "PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin\"; export PATH;\n"
        )

        XCTAssertEqual(
            paths,
            [
                "/usr/bin",
                "/bin",
                "/Users/tester/.local/bin",
                "/Users/tester/go/bin",
                "/Users/tester/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/opt/homebrew/sbin",
                "/usr/local/sbin",
                "/usr/sbin",
                "/sbin",
            ]
        )
    }

    func testParsePathHelperPathsExtractsPathEntries() {
        XCTAssertEqual(
            RemoteSessionCoordinator.parsePathHelperPaths(
                "PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin\"; export PATH;\n"
            ),
            [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
            ]
        )
    }

    func testParsePathHelperPathsIgnoresMANPATHAssignments() {
        XCTAssertEqual(
            RemoteSessionCoordinator.parsePathHelperPaths(
                """
                MANPATH="/opt/homebrew/share/man:/usr/share/man"; export MANPATH;
                PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin"; export PATH;
                """
            ),
            [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
            ]
        )
    }

    @MainActor
    func testRemoteTerminalSurfaceLookupTracksOnlyActiveSSHSurfaces() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(panelID))

        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64007)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(panelID))
    }

    @MainActor
    func testWebSocketRemoteTerminalEndLeavesConnectedStateWithinBoundedTime() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:issue-4509",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "cmux vm-pty-attach --id issue-4509",
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "wss://vm.example.invalid/daemon",
                headers: [:],
                token: "token",
                sessionId: "session",
                expiresAtUnix: 4_102_444_800
            ),
            skipDaemonBootstrap: true
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to vm:issue-4509 via shared local proxy 127.0.0.1:59999",
            target: "vm:issue-4509"
        )
        XCTAssertTrue(workspace.isRemoteTerminalSurface(panelID))
        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, true)

        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: nil)

        let deadline = Date().addingTimeInterval(0.5)
        while workspace.remoteConnectionState == .connected && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertNotEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
    }

    @MainActor
    func testWebSocketRemoteTerminalEndWithoutStartupCommandStillDisconnects() throws {
        let workspace = Workspace()
        let initialConfig = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:issue-4509-no-startup",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "cmux vm-pty-attach --id issue-4509-no-startup",
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "wss://vm.example.invalid/daemon",
                headers: [:],
                token: "token",
                sessionId: "session",
                expiresAtUnix: 4_102_444_800
            ),
            skipDaemonBootstrap: true
        )
        let config = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:issue-4509-no-startup",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "wss://vm.example.invalid/daemon",
                headers: [:],
                token: "token",
                sessionId: "session",
                expiresAtUnix: 4_102_444_800
            ),
            skipDaemonBootstrap: true
        )

        workspace.configureRemoteConnection(initialConfig, autoConnect: false)
        workspace.configureRemoteConnection(config, autoConnect: false)
        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to vm:issue-4509-no-startup",
            target: "vm:issue-4509-no-startup"
        )
        XCTAssertTrue(workspace.isRemoteTerminalSurface(panelID))

        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: nil)

        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    @MainActor
    func testRemoteTerminalSessionEndPublishesDisconnectedDetailWithoutTransientNil() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini",
            target: "cmux-macmini"
        )

        let expectedDetail = String(
            localized: "remote.status.terminalDisconnected",
            defaultValue: "Remote terminal session disconnected"
        )
        var publishedDetails: [String?] = []
        let cancellable = workspace.remoteConnectionDetailPublisher
            .dropFirst()
            .sink { publishedDetails.append($0) }
        defer { cancellable.cancel() }

        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64007)

        XCTAssertEqual(workspace.remoteConnectionDetail, expectedDetail)
        XCTAssertEqual(publishedDetails, [expectedDetail])
    }

    @MainActor
    func testRemoteTerminalSessionEndIgnoresDuplicateRelayCallbackAfterSurfaceProcessed() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64034,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: nil)
        let replacement = workspace.createReplacementTerminalPanel()
        let firstReplacementCommand = replacement.surface.initialCommand

        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64034)
        let secondReplacement = workspace.createReplacementTerminalPanel()

        XCTAssertNotNil(firstReplacementCommand)
        XCTAssertNil(secondReplacement.surface.initialCommand)
    }

    @MainActor
    func testForegroundSSHAuthReadyBeforeRemoteConfigureStartsDeferredConnect() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64029,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-a"
        )

        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-a")
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.remoteConnectionState, .connecting)
        workspace.disconnectRemoteConnection(clearConfiguration: true)
    }

    @MainActor
    func testForegroundSSHAuthReadyReconnectsConfiguredDisconnectedRemoteWorkspace() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64030,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-a"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)

        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-a")

        XCTAssertEqual(workspace.remoteConnectionState, .connecting)
        workspace.disconnectRemoteConnection(clearConfiguration: true)
    }

    @MainActor
    func testForegroundSSHAuthReadyBufferedTokenDoesNotReconnectDifferentConfiguration() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64031,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-b"
        )

        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-a")
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    func testRemoteReconnectingStateIsExposedInStatusPayload() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64033,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Reconnecting to cmux-macmini",
            target: "cmux-macmini"
        )

        XCTAssertEqual(workspace.remoteConnectionState, .reconnecting)
        XCTAssertEqual(workspace.remoteStatusPayload()["state"] as? String, "reconnecting")
    }

    @MainActor
    func testForegroundSSHAuthReadyIgnoresMismatchedConfiguredToken() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64032,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-a"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-b")

        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    func testRemoteTerminalSessionEndRequestsControlMasterCleanupAndLeavesWorkspaceDisconnected() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64012,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64012)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-o", "StrictHostKeyChecking=accept-new",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testRemoteTerminalSessionEndWithoutCallbackRelayPortStillCleansControlMaster() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64035,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: nil)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testRemoteTerminalSessionEndPreservesPersistentPTYWorkspace() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64012,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-persist-end"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panelID)
        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64012)

        wait(for: [cleanupRequested], timeout: 0.2)

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
        XCTAssertEqual(workspace.remoteConfiguration?.preserveAfterTerminalExit, true)
        XCTAssertEqual(workspace.remoteConfiguration?.persistentDaemonSlot, "ssh-persist-end")
        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == panelID }?.terminal?.remotePTYSessionID,
            expectedSessionID
        )

        workspace.teardownAllPanels()
        XCTAssertTrue(workspace.panels.isEmpty)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConfiguration?.preserveAfterTerminalExit, true)
    }

    @MainActor
    func testTeardownRemoteConnectionRequestsControlMasterCleanupWhileStillConnecting() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64014,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connecting,
            detail: "Connecting to cmux-macmini",
            target: "cmux-macmini"
        )

        workspace.teardownRemoteConnection()

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testTeardownRemoteConnectionRequestsControlMasterCleanupWithoutExplicitControlPath() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64015,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connecting,
            detail: "Connecting to cmux-macmini",
            target: "cmux-macmini"
        )

        workspace.teardownRemoteConnection()

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testClosingRemoteWorkspaceRequestsControlMasterCleanup() throws {
        let manager = TabManager()
        let remainingWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let remoteWorkspace = manager.addWorkspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64018,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        remoteWorkspace.configureRemoteConnection(config, autoConnect: false)

        manager.closeWorkspace(remoteWorkspace)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs.first?.id, remainingWorkspace.id)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == remoteWorkspace.id }))
        XCTAssertFalse(remoteWorkspace.isRemoteWorkspace)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-o", "StrictHostKeyChecking=accept-new",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testDetachLastRemoteSurfacePreservesRemoteSessionWithoutCleanup() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64016,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)

        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(workspace.detachSurface(panelId: panelID))

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertTrue(detached.isRemoteTerminal)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)

        let reattachedSurfaceID = workspace.attachDetachedSurface(detached, inPane: paneID, focus: false)

        XCTAssertNotNil(reattachedSurfaceID)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(detached.panelId))
    }

    @MainActor
    func testClosingSourceWorkspaceAfterDetachingRemoteSurfaceSkipsControlMasterCleanup() throws {
        let manager = TabManager()
        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let destinationWorkspace = manager.addWorkspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64017,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        sourceWorkspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: panelID))
        let destinationPaneID = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        let restoredPanelID = destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertNotNil(restoredPanelID)
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))
        XCTAssertTrue(sourceWorkspace.panels.isEmpty)

        manager.closeWorkspace(sourceWorkspace)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == sourceWorkspace.id }))
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))
    }

    @MainActor
    func testClosingMixedSourceWorkspaceAfterDetachingLastRemoteSurfaceSkipsControlMasterCleanup() throws {
        let manager = TabManager()
        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let destinationWorkspace = manager.addWorkspace()
        let sourcePaneID = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64018,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        sourceWorkspace.configureRemoteConnection(config, autoConnect: false)
        _ = sourceWorkspace.newBrowserSurface(inPane: sourcePaneID, url: URL(string: "https://example.com"), focus: false)

        let panelID = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: panelID))
        let destinationPaneID = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        let restoredPanelID = destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertNotNil(restoredPanelID)
        XCTAssertEqual(sourceWorkspace.panels.count, 1)
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))

        manager.closeWorkspace(sourceWorkspace)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == sourceWorkspace.id }))
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))
    }

    @MainActor
    func testTransferredRemoteSurfaceCleansUpControlMasterWhenSessionEndsInLocalWorkspace() throws {
        let manager = TabManager()
        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let destinationWorkspace = manager.addWorkspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64019,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var cleanupArguments: [[String]] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            cleanupArguments.append(arguments)
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        sourceWorkspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: panelID))
        let destinationPaneID = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        let restoredPanelID = destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertNotNil(restoredPanelID)
        XCTAssertFalse(destinationWorkspace.isRemoteWorkspace)
        XCTAssertEqual(destinationWorkspace.activeRemoteTerminalSessionCount, 0)

        manager.closeWorkspace(sourceWorkspace)
        destinationWorkspace.markRemoteTerminalSessionEnded(surfaceId: detached.panelId, relayPort: config.relayPort)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertEqual(cleanupArguments.count, 1)
        XCTAssertEqual(cleanupArguments.first?.suffix(2), ["exit", "cmux-macmini"])
    }

    @MainActor
    func testRemoteTerminalSessionEndDisconnectsWorkspaceWhenBrowserPanelsRemain() throws {
        let workspace = Workspace()
        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let initialTerminalID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64013,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)
        _ = workspace.newBrowserSurface(inPane: paneID, url: URL(string: "https://example.com"), focus: false)

        workspace.markRemoteTerminalSessionEnded(surfaceId: initialTerminalID, relayPort: 64013)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    @MainActor
    func testClosingInitialRemoteTerminalPaneKeepsSiblingRemotePaneAlive() throws {
        let workspace = Workspace()
        let initialTerminalID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64020,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        var cleanupArguments: [[String]] = []
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            cleanupArguments.append(arguments)
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let siblingTerminal = try XCTUnwrap(
            workspace.newTerminalSplit(from: initialTerminalID, orientation: .horizontal)
        )

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 2)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(initialTerminalID))
        XCTAssertTrue(workspace.isRemoteTerminalSurface(siblingTerminal.id))

        XCTAssertTrue(workspace.closePanel(initialTerminalID, force: true))

        XCTAssertNil(workspace.panels[initialTerminalID])
        XCTAssertNotNil(workspace.panels[siblingTerminal.id])
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(initialTerminalID))
        XCTAssertTrue(workspace.isRemoteTerminalSurface(siblingTerminal.id))
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        wait(for: [cleanupRequested], timeout: 0.2)
        XCTAssertTrue(cleanupArguments.isEmpty)
    }

    func testRemoteDropPathUsesLowercasedExtensionAndProvidedUUID() throws {
        let fileURL = URL(fileURLWithPath: "/Users/test/Screen Shot.PNG")
        let uuid = try XCTUnwrap(UUID(uuidString: "12345678-1234-1234-1234-1234567890AB"))

        let remotePath = RemoteSessionCoordinator.remoteDropPath(for: fileURL, uuid: uuid)

        XCTAssertEqual(remotePath, "/tmp/cmux-drop-12345678-1234-1234-1234-1234567890ab.png")
    }

    @MainActor
    func testDaemonBootstrapUploadUsesAbsoluteHomePathForScpDestination() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let fakeDaemonURL = directoryURL.appendingPathComponent("cmuxd-remote", isDirectory: false)
        try Data("fake daemon".utf8).write(to: fakeDaemonURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDaemonURL.path)

        let previousAllowLocalBuild = getenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD").map { String(cString: $0) }
        let previousDaemonBinary = getenv("CMUX_REMOTE_DAEMON_BINARY").map { String(cString: $0) }
        setenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD", "1", 1)
        setenv("CMUX_REMOTE_DAEMON_BINARY", fakeDaemonURL.path, 1)
        defer {
            if let previousAllowLocalBuild {
                setenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD", previousAllowLocalBuild, 1)
            } else {
                unsetenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD")
            }
            if let previousDaemonBinary {
                setenv("CMUX_REMOTE_DAEMON_BINARY", previousDaemonBinary, 1)
            } else {
                unsetenv("CMUX_REMOTE_DAEMON_BINARY")
            }
        }

        let scpInvoked = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var scpDestination: String?
        let remoteProcessScript: RemoteProcessScript = { executable, arguments, _, _ in
            if executable == "/usr/bin/ssh" {
                let command = arguments.last ?? ""
                if command.contains("uname -s") {
                    return (
                        status: 0,
                        stdout: """
                        __CMUX_REMOTE_HOME__=/home/test
                        __CMUX_REMOTE_OS__=Linux
                        __CMUX_REMOTE_ARCH__=x86_64
                        __CMUX_REMOTE_EXISTS__=no
                        """,
                        stderr: ""
                    )
                }
                if command.contains("mkdir -p") {
                    return (status: 0, stdout: "", stderr: "")
                }
                return (status: 0, stdout: "", stderr: "")
            }
            if executable == "/usr/bin/scp" {
                lock.lock()
                scpDestination = arguments.last
                lock.unlock()
                scpInvoked.signal()
                return (status: 1, stdout: "", stderr: "intentional stop after upload destination capture")
            }
            XCTFail("unexpected executable \(executable)")
            return (status: 1, stdout: "", stderr: "unexpected executable")
        }

        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting =
            ScriptedRemoteProcessRunner(script: remoteProcessScript)
        let config = WorkspaceRemoteConfiguration(
            destination: "test@hpc.example",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh test@hpc.example"
        )
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(scpInvoked.wait(timeout: .now() + 2), .success)
        lock.lock()
        let capturedDestination = scpDestination
        lock.unlock()
        let destination = try XCTUnwrap(capturedDestination)
        XCTAssertTrue(
            destination.hasPrefix("test@hpc.example:/home/test/.cmux/bin/cmuxd-remote/"),
            "expected scp to target an absolute path under remote HOME, got \(destination)"
        )
        XCTAssertTrue(
            destination.contains("/linux-amd64/cmuxd-remote.tmp-"),
            "expected daemon platform temp path in \(destination)"
        )
    }

    @MainActor
    func testPersistentPTYBootstrapReinstallsOldDaemonMissingPTYCapability() throws {
        let previousAllowLocalBuild = getenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD").map { String(cString: $0) }
        let previousDaemonBinary = getenv("CMUX_REMOTE_DAEMON_BINARY").map { String(cString: $0) }
        setenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD", "1", 1)
        unsetenv("CMUX_REMOTE_DAEMON_BINARY")
        defer {
            if let previousAllowLocalBuild {
                setenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD", previousAllowLocalBuild, 1)
            } else {
                unsetenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD")
            }
            if let previousDaemonBinary {
                setenv("CMUX_REMOTE_DAEMON_BINARY", previousDaemonBinary, 1)
            } else {
                unsetenv("CMUX_REMOTE_DAEMON_BINARY")
            }
        }

        let scpInvoked = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var scpDestination: String?
        let remoteProcessScript: RemoteProcessScript = { executable, arguments, _, _ in
            let executableName = URL(fileURLWithPath: executable).lastPathComponent
            if executable == "/usr/bin/ssh" {
                let command = arguments.last ?? ""
                if command.contains("uname -s") {
                    return (
                        status: 0,
                        stdout: """
                        __CMUX_REMOTE_HOME__=/home/test
                        __CMUX_REMOTE_OS__=Linux
                        __CMUX_REMOTE_ARCH__=x86_64
                        __CMUX_REMOTE_EXISTS__=yes
                        """,
                        stderr: ""
                    )
                }
                if remoteDaemonServeCommand(command) {
                    return (
                        status: 0,
                        stdout: #"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"old","capabilities":["proxy.stream.push"]}}"# + "\n",
                        stderr: ""
                    )
                }
                if command.contains("mkdir -p") {
                    return (status: 0, stdout: "", stderr: "")
                }
                return (status: 0, stdout: "", stderr: "")
            }
            if executable == "/usr/bin/scp" {
                lock.lock()
                scpDestination = arguments.last
                lock.unlock()
                scpInvoked.signal()
                return (status: 1, stdout: "", stderr: "intentional stop after capability reinstall")
            }
            if executableName == "go" {
                if let outputFlagIndex = arguments.firstIndex(of: "-o"),
                   outputFlagIndex + 1 < arguments.count {
                    let outputURL = URL(fileURLWithPath: arguments[outputFlagIndex + 1], isDirectory: false)
                    try? FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data("fake daemon".utf8).write(to: outputURL)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outputURL.path)
                }
                return (status: 0, stdout: "", stderr: "")
            }
            XCTFail("unexpected executable \(executable)")
            return (status: 1, stdout: "", stderr: "unexpected executable")
        }

        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting =
            ScriptedRemoteProcessRunner(script: remoteProcessScript)
        let config = WorkspaceRemoteConfiguration(
            destination: "test@hpc.example",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(scpInvoked.wait(timeout: .now() + 2), .success)
        lock.lock()
        let capturedDestination = scpDestination
        lock.unlock()
        let destination = try XCTUnwrap(capturedDestination)
        XCTAssertTrue(
            destination.hasPrefix("test@hpc.example:/home/test/.cmux/bin/cmuxd-remote/"),
            "expected missing pty.session to reinstall the old daemon, got \(destination)"
        )
    }

    @MainActor
    func testPersistentReverseRelayCancelsStaleControlMasterForwardBeforeReusingRelayPort() throws {
        let forwardInvoked = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var controlOperations: [(command: String, spec: String)] = []

        let remoteProcessScript: RemoteProcessScript = { executable, arguments, _, _ in
            guard executable == "/usr/bin/ssh" else {
                XCTFail("unexpected executable \(executable)")
                return (status: 1, stdout: "", stderr: "unexpected executable")
            }

            if let controlOperation = remoteReverseRelayControlOperation(from: arguments) {
                let operation = controlOperation.command
                let spec = controlOperation.spec
                lock.lock()
                controlOperations.append((command: operation, spec: spec))
                lock.unlock()
                if operation == "forward" {
                    forwardInvoked.signal()
                }
                return (status: 0, stdout: "", stderr: "")
            }

            let command = arguments.last ?? ""
            if command.contains("uname -s") {
                return (
                    status: 0,
                    stdout: """
                    __CMUX_REMOTE_HOME__=/home/test
                    __CMUX_REMOTE_OS__=Linux
                    __CMUX_REMOTE_ARCH__=x86_64
                    __CMUX_REMOTE_EXISTS__=yes
                    """,
                    stderr: ""
                )
            }
            if remoteDaemonServeCommand(command) {
                return (
                    status: 0,
                    stdout: #"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"dev","capabilities":["proxy.stream.push","pty.session","pty.session.token","pty.write.notification","pty.resize.notification","pty.session.persistent_daemon"]}}"# + "\n",
                    stderr: ""
                )
            }
            return (status: 0, stdout: "", stderr: "")
        }

        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting =
            ScriptedRemoteProcessRunner(script: remoteProcessScript)
        let config = WorkspaceRemoteConfiguration(
            destination: "test@hpc.example",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-\(getuid())-64044-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64044,
            relayID: "relay-stale-forward",
            relayToken: String(repeating: "c", count: 64),
            localSocketPath: "/tmp/cmux-stale-forward-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-stale-forward-test"
        )
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(forwardInvoked.wait(timeout: .now() + 2), .success)
        lock.lock()
        let operations = controlOperations
        lock.unlock()

        XCTAssertGreaterThanOrEqual(operations.count, 2)
        XCTAssertEqual(operations[0].command, "cancel")
        XCTAssertEqual(operations[0].spec, "127.0.0.1:64044")
        XCTAssertEqual(operations[1].command, "forward")
        XCTAssertTrue(
            operations[1].spec.hasPrefix("127.0.0.1:64044:127.0.0.1:"),
            "expected forward to reuse relay port after stale cancel, got \(operations[1].spec)"
        )
    }

    @MainActor
    func testPersistentReverseRelayCleansStaleRemoteListenerAndRetriesControlMasterForward() throws {
        let retryForwardInvoked = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var controlOperations: [(command: String, spec: String)] = []
        var forwardAttempts = 0
        var cleanupInvoked = false
        var cleanupArguments: [String] = []

        let remoteProcessScript: RemoteProcessScript = { executable, arguments, _, _ in
            guard executable == "/usr/bin/ssh" else {
                XCTFail("unexpected executable \(executable)")
                return (status: 1, stdout: "", stderr: "unexpected executable")
            }

            if let controlOperation = remoteReverseRelayControlOperation(from: arguments) {
                let operation = controlOperation.command
                let spec = controlOperation.spec
                lock.lock()
                controlOperations.append((command: operation, spec: spec))
                if operation == "forward" {
                    forwardAttempts += 1
                    let attempt = forwardAttempts
                    lock.unlock()
                    if attempt == 1 {
                        return (
                            status: 255,
                            stdout: "",
                            stderr: "remote port forwarding failed for listen port 64045"
                        )
                    }
                    retryForwardInvoked.signal()
                    return (status: 0, stdout: "", stderr: "")
                }
                lock.unlock()
                return (status: 0, stdout: "", stderr: "")
            }

            let command = arguments.last ?? ""
            if command.contains("cmux_stale_relay_listener_cleanup=1") {
                lock.lock()
                cleanupInvoked = true
                cleanupArguments = arguments
                lock.unlock()
                return (
                    status: 0,
                    stdout: "cmux_stale_relay_killed pid=33681 children=34057 port=64045\n",
                    stderr: ""
                )
            }
            if command.contains("uname -s") {
                return (
                    status: 0,
                    stdout: """
                    __CMUX_REMOTE_HOME__=/home/test
                    __CMUX_REMOTE_OS__=Linux
                    __CMUX_REMOTE_ARCH__=x86_64
                    __CMUX_REMOTE_EXISTS__=yes
                    """,
                    stderr: ""
                )
            }
            if remoteDaemonServeCommand(command) {
                return (
                    status: 0,
                    stdout: #"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"dev","capabilities":["proxy.stream.push","pty.session","pty.session.token","pty.write.notification","pty.resize.notification","pty.session.persistent_daemon"]}}"# + "\n",
                    stderr: ""
                )
            }
            return (status: 0, stdout: "", stderr: "")
        }

        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting =
            ScriptedRemoteProcessRunner(script: remoteProcessScript)
        let config = WorkspaceRemoteConfiguration(
            destination: "test@hpc.example",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-\(getuid())-64045-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64045,
            relayID: "relay-stale-forward-retry",
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-stale-forward-retry.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-stale-forward-retry"
        )
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(retryForwardInvoked.wait(timeout: .now() + 2), .success)
        lock.lock()
        let operations = controlOperations
        let cleanupWasInvoked = cleanupInvoked
        let capturedCleanupArguments = cleanupArguments
        let attempts = forwardAttempts
        lock.unlock()

        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(cleanupWasInvoked)
        XCTAssertTrue(capturedCleanupArguments.contains("-S"))
        XCTAssertTrue(capturedCleanupArguments.contains("none"))
        XCTAssertFalse(capturedCleanupArguments.contains(where: { $0.hasPrefix("ControlPath=") }))
        XCTAssertGreaterThanOrEqual(operations.count, 3)
        XCTAssertEqual(operations[0].command, "cancel")
        XCTAssertEqual(operations[0].spec, "127.0.0.1:64045")
        XCTAssertEqual(operations[1].command, "forward")
        XCTAssertEqual(operations[2].command, "forward")
        XCTAssertEqual(operations[1].spec, operations[2].spec)
        XCTAssertTrue(operations[2].spec.hasPrefix("127.0.0.1:64045:127.0.0.1:"))
    }

    @MainActor
    func testDetachAttachPreservesRemoteTerminalSurfaceTracking() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)

        let originalPanelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let originalPaneID = try XCTUnwrap(workspace.paneId(forPanelId: originalPanelID))
        let movedPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: originalPanelID, orientation: .horizontal)
        )

        XCTAssertTrue(workspace.isRemoteTerminalSurface(originalPanelID))
        XCTAssertTrue(workspace.isRemoteTerminalSurface(movedPanel.id))

        let detached = try XCTUnwrap(workspace.detachSurface(panelId: movedPanel.id))
        XCTAssertTrue(detached.isRemoteTerminal)
        XCTAssertEqual(detached.remoteRelayPort, config.relayPort)

        let restoredPanelID = workspace.attachDetachedSurface(
            detached,
            inPane: originalPaneID,
            focus: false
        )

        XCTAssertEqual(restoredPanelID, movedPanel.id)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(movedPanel.id))
    }

    @MainActor
    func testDetachAttachPreservesPersistentPTYSessionIDAcrossWorkspaces() throws {
        let source = Workspace()
        let destination = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64008,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        source.configureRemoteConnection(config, autoConnect: false)
        destination.configureRemoteConnection(config, autoConnect: false)

        let sourcePanelID = try XCTUnwrap(source.focusedTerminalPanel?.id)
        let destinationPaneID = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let sessionID = "ssh-source-session"
        let movedPanel = try XCTUnwrap(
            source.newTerminalSplit(
                from: sourcePanelID,
                orientation: .horizontal,
                remotePTYSessionID: sessionID
            )
        )

        let detached = try XCTUnwrap(source.detachSurface(panelId: movedPanel.id))
        XCTAssertEqual(detached.remotePTYSessionID, sessionID)

        let restoredPanelID = destination.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertEqual(restoredPanelID, movedPanel.id)
        XCTAssertTrue(destination.isRemoteTerminalSurface(movedPanel.id))
        let snapshot = destination.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(
            snapshot.panels.first { $0.id == movedPanel.id }?.terminal?.remotePTYSessionID,
            sessionID
        )
    }

    @MainActor
    func testDetachAttachDoesNotAdoptPersistentPTYSessionIDAcrossNilRelayWorkspaces() throws {
        let source = Workspace()
        let destination = Workspace()
        let sourceConfig = WorkspaceRemoteConfiguration(
            destination: "source-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        let destinationConfig = WorkspaceRemoteConfiguration(
            destination: "destination-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        source.configureRemoteConnection(sourceConfig, autoConnect: false)
        destination.configureRemoteConnection(destinationConfig, autoConnect: false)

        let initialSourcePanelID = try XCTUnwrap(source.focusedTerminalPanel?.id)
        let sourcePaneID = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        let destinationPaneID = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let sessionID = "source-only-pty-session"
        let movedPanel = try XCTUnwrap(
            source.newTerminalSurface(
                inPane: sourcePaneID,
                focus: true,
                initialCommand: "cmux ssh-pty-attach",
                remotePTYSessionID: sessionID
            )
        )
        XCTAssertTrue(source.closePanel(initialSourcePanelID, force: true))
        XCTAssertTrue(source.isRemoteTerminalSurface(movedPanel.id))

        let detached = try XCTUnwrap(source.detachSurface(panelId: movedPanel.id))
        XCTAssertNil(detached.remoteRelayPort)
        XCTAssertEqual(detached.remotePTYSessionID, sessionID)
        XCTAssertEqual(detached.remoteCleanupConfiguration?.destination, "source-host")

        let restoredPanelID = destination.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertEqual(restoredPanelID, movedPanel.id)
        XCTAssertFalse(destination.isRemoteTerminalSurface(movedPanel.id))
        XCTAssertEqual(
            destination.transferredRemoteCleanupConfigurationsByPanelId[movedPanel.id]?.destination,
            "source-host"
        )
        let snapshot = destination.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(snapshot.panels.first { $0.id == movedPanel.id }?.terminal?.remotePTYSessionID)
    }

    @MainActor
    func testExplicitRemotePTYSessionSurfaceTracksRemoteTerminalWithoutDefaultStartup() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64009,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sessionID = "explicit-surface-session"
        let panel = try XCTUnwrap(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: false,
                initialCommand: "cmux ssh-pty-attach",
                remotePTYSessionID: sessionID
            )
        )

        XCTAssertTrue(workspace.isRemoteTerminalSurface(panel.id))
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(
            snapshot.panels.first { $0.id == panel.id }?.terminal?.remotePTYSessionID,
            sessionID
        )

        let outcome = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: sessionID)
        XCTAssertTrue(outcome.clearedRemotePTYSession)
        XCTAssertTrue(outcome.untrackedRemoteTerminal)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(panel.id))
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    @MainActor
    func testRemoteDisconnectClearsExplicitRemotePTYSessionIDBeforeReseed() throws {
        let workspace = Workspace()
        let explicitSessionConfig = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64011,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(explicitSessionConfig, autoConnect: false)

        let initialPanelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: true,
                initialCommand: "cmux ssh-pty-attach",
                remotePTYSessionID: "old-explicit-session"
            )
        )
        XCTAssertTrue(workspace.closePanel(initialPanelID, force: true))
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertTrue(workspace.remotePTYSessionIDMatches(panelId: panel.id, sessionID: "old-explicit-session"))

        workspace.disconnectRemoteConnection(clearConfiguration: true)

        let reseededConfig = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64012,
            relayID: String(repeating: "c", count: 16),
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(reseededConfig, autoConnect: false)

        let defaultSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panel.id)
        XCTAssertTrue(workspace.remotePTYSessionIDMatches(panelId: panel.id, sessionID: defaultSessionID))
        let outcome = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: defaultSessionID)
        XCTAssertTrue(outcome.clearedRemotePTYSession)
        XCTAssertTrue(outcome.untrackedRemoteTerminal)
    }

    @MainActor
    func testRemoteReconfigureClearsExplicitRemotePTYSessionIDForTrackedSurface() throws {
        let workspace = Workspace()
        let originalConfig = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64013,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(originalConfig, autoConnect: false)

        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: true,
                initialCommand: "cmux ssh-pty-attach",
                remotePTYSessionID: "old-explicit-session"
            )
        )
        XCTAssertTrue(workspace.remotePTYSessionIDMatches(panelId: panel.id, sessionID: "old-explicit-session"))

        let replacementConfig = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64014,
            relayID: String(repeating: "c", count: 16),
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(replacementConfig, autoConnect: false)

        let defaultSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panel.id)
        XCTAssertTrue(workspace.remotePTYSessionIDMatches(panelId: panel.id, sessionID: defaultSessionID))
    }

    @MainActor
    func testExplicitRemotePTYSessionSplitTracksRemoteTerminalWithoutDefaultStartup() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64010,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        let sourcePanelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let sessionID = "explicit-split-session"
        let panel = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: sourcePanelID,
                orientation: .horizontal,
                initialCommand: "cmux ssh-pty-attach",
                remotePTYSessionID: sessionID
            )
        )

        XCTAssertTrue(workspace.isRemoteTerminalSurface(panel.id))
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(
            snapshot.panels.first { $0.id == panel.id }?.terminal?.remotePTYSessionID,
            sessionID
        )
    }

    @MainActor
    func testPersistentRemoteTerminalSeedsDefaultPTYSessionIDForSnapshot() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64015,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-seeded-default"
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panelID)

        XCTAssertTrue(workspace.remotePTYSessionIDMatches(panelId: panelID, sessionID: expectedSessionID))
        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == panelID }?.terminal?.remotePTYSessionID,
            expectedSessionID
        )
    }

    @MainActor
    func testDetachAttachPreservesSurfaceTTYMetadata() throws {
        let source = Workspace()
        let destination = Workspace()

        let panelID = try XCTUnwrap(source.focusedTerminalPanel?.id)
        let sourcePaneID = try XCTUnwrap(source.paneId(forPanelId: panelID))
        let destinationPaneID = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        source.surfaceTTYNames[panelID] = "/dev/ttys004"

        let detached = try XCTUnwrap(source.detachSurface(panelId: panelID))
        XCTAssertEqual(source.surfaceTTYNames[panelID], nil)

        let restoredPanelID = destination.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertEqual(restoredPanelID, panelID)
        XCTAssertEqual(destination.surfaceTTYNames[panelID], "/dev/ttys004")
        XCTAssertEqual(source.bonsplitController.tabs(inPane: sourcePaneID).count, 0)
    }

    func testDetectedSSHUploadFailureCleansUpEarlierRemoteUploads() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-detected-ssh-upload-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let firstFileURL = directoryURL.appendingPathComponent("first.png")
        let secondFileURL = directoryURL.appendingPathComponent("second.png")
        try Data("first".utf8).write(to: firstFileURL)
        try Data("second".utf8).write(to: secondFileURL)

        let session = DetectedSSHSession(
            destination: "lawrence@example.com",
            port: 2200,
            identityFile: "/Users/test/.ssh/id_ed25519",
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        var invocations: [(executable: String, arguments: [String])] = []
        var scpInvocationCount = 0
        DetectedSSHSession.runProcessOverrideForTesting = { executable, arguments, _, _ in
            invocations.append((executable, arguments))
            if executable == "/usr/bin/scp" {
                scpInvocationCount += 1
                if scpInvocationCount == 1 {
                    return (status: 0, stdout: "", stderr: "")
                }
                return (status: 1, stdout: "", stderr: "copy failed")
            }
            if executable == "/usr/bin/ssh" {
                return (status: 0, stdout: "", stderr: "")
            }
            XCTFail("unexpected executable \(executable)")
            return (status: 1, stdout: "", stderr: "unexpected executable")
        }
        defer { DetectedSSHSession.runProcessOverrideForTesting = nil }

        XCTAssertThrowsError(
            try session.uploadDroppedFilesSyncForTesting([firstFileURL, secondFileURL])
        )

        let firstSCPDestination = try XCTUnwrap(
            invocations
                .first(where: { $0.executable == "/usr/bin/scp" })?
                .arguments
                .last
        )
        let uploadedRemotePath = try XCTUnwrap(firstSCPDestination.split(separator: ":", maxSplits: 1).last)
        let cleanupInvocation = try XCTUnwrap(
            invocations.first(where: { $0.executable == "/usr/bin/ssh" })
        )
        let cleanupCommand = cleanupInvocation.arguments.joined(separator: " ")

        XCTAssertTrue(cleanupCommand.contains(String(uploadedRemotePath)))
    }

    func testDetectsForegroundSSHSessionForTTY() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=/tmp/cmux-ssh-%C",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-p", "2200",
                    "-i", "/Users/test/.ssh/id_ed25519",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(
            session,
            DetectedSSHSession(
                destination: "lawrence@example.com",
                port: 2200,
                identityFile: "/Users/test/.ssh/id_ed25519",
                configFile: nil,
                jumpHost: nil,
                controlPath: "/tmp/cmux-ssh-%C",
                useIPv4: false,
                useIPv6: false,
                forwardAgent: false,
                compressionEnabled: false,
                sshOptions: [
                    "StrictHostKeyChecking=accept-new",
                ]
            )
        )
    }

    func testDetectsForegroundSSHSessionWithShortControlPathFlag() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-S", "/tmp/cmux-ssh-%C",
                    "-p", "2200",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.controlPath, "/tmp/cmux-ssh-%C")
        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertTrue(scpArgs.contains("ControlPath=/tmp/cmux-ssh-%C"))
        XCTAssertFalse(scpArgs.contains("-S"))
    }

    func testDetectsForegroundEternalTerminalSessionForTTY() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "/opt/homebrew/bin/et",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(
            session,
            DetectedSSHSession(
                destination: "lawrence@example.com",
                port: nil,
                identityFile: nil,
                configFile: nil,
                jumpHost: nil,
                controlPath: nil,
                useIPv4: false,
                useIPv6: false,
                forwardAgent: false,
                compressionEnabled: false,
                sshOptions: []
            )
        )
    }

    func testDetectsEternalTerminalSessionWithoutTreatingETPortAsSSHPort() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "-u", "lawrence",
                    "-p", "2022",
                    "--jport", "2023",
                    "example.com:2024",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@example.com")
        XCTAssertNil(session?.port)

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertEqual(scpArgs.last, "lawrence@example.com:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionWithBracketedIPv6ServerPortForSCP() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "-u", "lawrence",
                    "[2001:db8::1]:2022",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@[2001:db8::1]")

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertNil(session?.port)
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertEqual(scpArgs.last, "lawrence@[2001:db8::1]:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionWithFullIPv6ServerPortForSCP() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "-u", "lawrence",
                    "2001:db8:0:0:0:0:0:1:2022",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@[2001:db8:0:0:0:0:0:1]")

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertNil(session?.port)
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertEqual(scpArgs.last, "lawrence@[2001:db8:0:0:0:0:0:1]:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionPreservesAmbiguousCompressedIPv6LiteralForSCP() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "-u", "lawrence",
                    "2001:db8::1:2022",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@2001:db8::1:2022")

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertNil(session?.port)
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertEqual(scpArgs.last, "lawrence@[2001:db8::1:2022]:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionIgnoresOptionsAfterDestination() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "lawrence@example.com",
                    "--ssh-option", "Port=2200",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@example.com")
        XCTAssertNil(session?.port)

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertEqual(scpArgs.last, "lawrence@example.com:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionStripsNativeJumpHostServerPortForSCP() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "--jumphost", "relay@bastion.example.com:2022",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.jumpHost, "relay@bastion.example.com")

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertNil(session?.port)
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertTrue(scpArgs.contains("-J"))
        XCTAssertTrue(scpArgs.contains("relay@bastion.example.com"))
        XCTAssertFalse(scpArgs.contains("relay@bastion.example.com:2022"))
        XCTAssertEqual(scpArgs.last, "lawrence@example.com:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionSSHOptionsForSCP() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "--ssh-option", "Port=2200",
                    "--ssh-option=IdentityFile=/Users/test/.ssh/id_ed25519",
                    "--ssh-option", "ControlPath=/tmp/cmux-ssh-%C",
                    "--ssh-option", "StrictHostKeyChecking=accept-new",
                    "--jumphost", "bastion.example.com",
                    "--command", "uptime",
                    "-x",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(
            session,
            DetectedSSHSession(
                destination: "lawrence@example.com",
                port: 2200,
                identityFile: "/Users/test/.ssh/id_ed25519",
                configFile: nil,
                jumpHost: "bastion.example.com",
                controlPath: "/tmp/cmux-ssh-%C",
                useIPv4: false,
                useIPv6: false,
                forwardAgent: false,
                compressionEnabled: false,
                sshOptions: [
                    "StrictHostKeyChecking=accept-new",
                ]
            )
        )
    }

    func testDaemonTransportArgumentsReuseConfiguredControlPath() {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-macmini"
        )

        let arguments = configuration.daemonTransportArguments(
            remotePath: "/remote/cmuxd-remote"
        )

        XCTAssertFalse(arguments.contains("-S"))
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains(where: { $0 == "ControlPath /tmp/cmux-ssh-%C" || $0 == "ControlPath=/tmp/cmux-ssh-%C" }))
        XCTAssertTrue(arguments.contains("cmux-macmini"))
        XCTAssertTrue(arguments.last?.contains("/remote/cmuxd-remote") ?? false)
    }

    func testDaemonTransportArgumentsReuseWhitespaceConfiguredControlPath() {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster auto",
                "ControlPersist 600",
                "ControlPath /tmp/cmux-ssh-%C",
                "StrictHostKeyChecking accept-new",
            ],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-macmini"
        )

        let arguments = configuration.daemonTransportArguments(
            remotePath: "/remote/cmuxd-remote"
        )

        XCTAssertFalse(arguments.contains("-S"))
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains(where: { $0 == "ControlPath /tmp/cmux-ssh-%C" || $0 == "ControlPath=/tmp/cmux-ssh-%C" }))
    }

    func testReverseRelayControlMasterArgumentsReuseConfiguredControlSocket() throws {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-macmini"
        )

        let arguments = try XCTUnwrap(
            configuration.reverseRelayControlMasterArguments(
                controlCommand: "forward",
                forwardSpec: "127.0.0.1:64007:127.0.0.1:54321"
            )
        )

        XCTAssertFalse(arguments.contains("-S"))
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains("ControlPath=/tmp/cmux-ssh-%C"))
        XCTAssertTrue(arguments.contains("-O"))
        XCTAssertTrue(arguments.contains("forward"))
        XCTAssertTrue(arguments.contains("-R"))
        XCTAssertTrue(arguments.contains("127.0.0.1:64007:127.0.0.1:54321"))
        XCTAssertTrue(arguments.contains("cmux-macmini"))
    }

    func testReverseRelayControlMasterCancelArgumentsUseRemoteListenPortOnly() throws {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-macmini"
        )

        let arguments = try XCTUnwrap(
            configuration.reverseRelayControlMasterCancelArguments(
                relayPort: 64007
            )
        )

        XCTAssertFalse(arguments.contains("-S"))
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains("ControlPath=/tmp/cmux-ssh-%C"))
        XCTAssertTrue(arguments.contains("-O"))
        XCTAssertTrue(arguments.contains("cancel"))
        XCTAssertTrue(arguments.contains("-R"))
        XCTAssertTrue(arguments.contains("127.0.0.1:64007"))
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("127.0.0.1:64007:127.0.0.1:") }))
        XCTAssertTrue(arguments.contains("cmux-macmini"))
    }

    func testReverseRelayControlMasterArgumentsReuseWhitespaceConfiguredControlSocket() throws {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster auto",
                "ControlPersist 600",
                "ControlPath /tmp/cmux-ssh-%C",
                "StrictHostKeyChecking accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64033,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-macmini"
        )

        let arguments = try XCTUnwrap(
            configuration.reverseRelayControlMasterArguments(
                controlCommand: "forward",
                forwardSpec: "127.0.0.1:64033:127.0.0.1:54321"
            )
        )

        XCTAssertFalse(arguments.contains("-S"))
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains(where: { $0 == "ControlPath /tmp/cmux-ssh-%C" || $0 == "ControlPath=/tmp/cmux-ssh-%C" }))
        XCTAssertTrue(arguments.contains("-O"))
        XCTAssertTrue(arguments.contains("forward"))
    }

    func testDetectedSSHSessionBracketsIPv6LiteralSCPDestination() {
        let session = DetectedSSHSession(
            destination: "lawrence@2001:db8::1",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        let scpArgs = session.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        )

        XCTAssertEqual(scpArgs.last, "lawrence@[2001:db8::1]:/tmp/cmux-drop-123.png")
    }

    func testDetectsForegroundSSHSessionWithLowercaseAgentFlag() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-a",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@example.com")
        XCTAssertFalse(session?.forwardAgent ?? true)
    }

    func testDetectsForegroundSSHSessionIgnoringBindInterfaceValue() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-B", "en0",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@example.com")
    }

    func testIgnoresBackgroundSSHProcessForTTY() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "ttys004",
            processes: [
                .init(pid: 2145, pgid: 2145, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: ["ssh", "lawrence@example.com"],
            ]
        )

        XCTAssertNil(session)
    }

    @MainActor
    func testProxyOnlyErrorsKeepSSHWorkspaceConnectedAndLoggedInSidebar() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        let proxyError = "Remote proxy to cmux-macmini unavailable: Failed to start local daemon proxy: daemon RPC timeout waiting for hello response (retry in 3s)"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "cmux-macmini")

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
        XCTAssertEqual(
            workspace.statusEntries["remote.error"]?.value,
            "Remote proxy unavailable (cmux-macmini): \(proxyError)"
        )
        XCTAssertEqual(workspace.logEntries.last?.source, "remote-proxy")
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, true)
        XCTAssertEqual(
            ((workspace.remoteStatusPayload()["proxy"] as? [String: Any])?["state"] as? String),
            "error"
        )

        workspace.applyRemoteConnectionStateUpdate(.connecting, detail: "Connecting to cmux-macmini", target: "cmux-macmini")

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(
            workspace.statusEntries["remote.error"]?.value,
            "Remote proxy unavailable (cmux-macmini): \(proxyError)"
        )

        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:9999",
            target: "cmux-macmini"
        )

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertNil(workspace.statusEntries["remote.error"])
        XCTAssertEqual(
            ((workspace.remoteStatusPayload()["proxy"] as? [String: Any])?["state"] as? String),
            "unavailable"
        )
    }

    @MainActor
    func testDefaultCloudProxyOnlyErrorsDoNotPolluteConnectedSidebar() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cloud VM",
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64015,
            relayID: String(repeating: "e", count: 16),
            relayToken: String(repeating: "f", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            managedCloudVMID: "71smiccrg35sw9pydt8k",
            terminalStartupCommand: "cmux vm ssh-attach --id 71smiccrg35sw9pydt8k --default-freestyle-sshd",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "cmux-default-freestyle-sshd-v1",
            skipDaemonBootstrap: true
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        let proxyError = "Remote proxy to cloud VM unavailable: Failed to start local daemon proxy: timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "cloud VM")

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertNil(workspace.statusEntries["remote.error"])
        XCTAssertNil(workspace.logEntries.last(where: { $0.source == "remote-proxy" }))
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, true)

        workspace.statusEntries["remote.error"] = SidebarStatusEntry(
            key: "remote.error",
            value: "Remote proxy unavailable (cloud VM): \(proxyError)",
            icon: "exclamationmark.triangle.fill",
            color: nil,
            timestamp: Date()
        )
        workspace.logEntries.append(
            SidebarLogEntry(
                message: "Remote proxy unavailable (cloud VM): \(proxyError)",
                level: .error,
                source: "remote-proxy",
                timestamp: Date()
            )
        )
        workspace.applyRemoteConnectionStateUpdate(.reconnecting, detail: "Reconnecting to cloud VM", target: "cloud VM")

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertNil(workspace.statusEntries["remote.error"])
        XCTAssertNil(workspace.logEntries.last(where: { $0.source == "remote-proxy" }))

        workspace.logEntries.append(
            SidebarLogEntry(
                message: "Remote proxy unavailable (cloud VM): \(proxyError)",
                level: .error,
                source: "remote-proxy",
                timestamp: Date()
            )
        )

        XCTAssertNil(
            workspace.sessionSnapshot(includeScrollback: false)
                .logEntries
                .last(where: { $0.source == "remote-proxy" })
        )

        var legacySnapshot = workspace.sessionSnapshot(includeScrollback: false)
        legacySnapshot.logEntries = [
            SessionLogEntrySnapshot(
                message: "Remote proxy unavailable (cloud VM): \(proxyError)",
                level: SidebarLogLevel.error.rawValue,
                source: "remote-proxy",
                timestamp: Date().timeIntervalSince1970
            )
        ]

        let restored = Workspace()
        restored.restoreSessionSnapshot(legacySnapshot)

        XCTAssertNil(restored.logEntries.last(where: { $0.source == "remote-proxy" }))
    }

    @MainActor
    func testWebSocketDaemonTransportErrorClearsConnectedSidebarState() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:issue-4509",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "cmux vm-pty-attach --id issue-4509",
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "wss://vm.example.invalid/daemon",
                headers: [:],
                token: "token",
                sessionId: "session",
                expiresAtUnix: 4_102_444_800
            ),
            skipDaemonBootstrap: true
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to vm:issue-4509 via shared local proxy 127.0.0.1:59999",
            target: "vm:issue-4509"
        )

        let proxyError = "Remote proxy to vm:issue-4509 unavailable: Remote daemon transport failed: daemon websocket keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "vm:issue-4509")

        XCTAssertEqual(workspace.remoteConnectionState, .error)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
        XCTAssertEqual(
            ((workspace.remoteStatusPayload()["proxy"] as? [String: Any])?["state"] as? String),
            "error"
        )
    }
}

final class CLINotifyProcessIntegrationTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private struct PTYAttachCall {
        let sessionID: String
        let attachmentID: String
        let command: String?
        let requireExisting: Bool
    }

    private final class ImmediateExitPTYBridgeRPC: RemotePTYBridgeRPCClient, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedAttachCalls: [PTYAttachCall] = []

        var attachCalls: [PTYAttachCall] {
            lock.lock()
            defer { lock.unlock() }
            return recordedAttachCalls
        }

        func attachBridgePTY(
            sessionID: String,
            attachmentID: String,
            cols: Int,
            rows: Int,
            command: String?,
            requireExisting: Bool,
            queue: DispatchQueue,
            onEvent: @escaping (RemotePTYBridgeEvent) -> Void
        ) throws -> RemotePTYBridgeAttachment {
            lock.lock()
            recordedAttachCalls.append(PTYAttachCall(
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting
            ))
            lock.unlock()
            queue.async {
                onEvent(.exit)
            }
            return RemotePTYBridgeAttachment(attachmentID: attachmentID, token: "immediate-token")
        }

        func writePTY(
            sessionID: String,
            attachmentID: String,
            attachmentToken: String,
            data: Data,
            completion: @escaping (Error?) -> Void
        ) {
            completion(nil)
        }
        func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}
    }

    private final class ImmediateOutputThenExitPTYBridgeRPC: RemotePTYBridgeRPCClient, @unchecked Sendable {
        func attachBridgePTY(
            sessionID: String,
            attachmentID: String,
            cols: Int,
            rows: Int,
            command: String?,
            requireExisting: Bool,
            queue: DispatchQueue,
            onEvent: @escaping (RemotePTYBridgeEvent) -> Void
        ) throws -> RemotePTYBridgeAttachment {
            queue.async {
                onEvent(.data(Data("early-output".utf8)))
                onEvent(.exit)
            }
            return RemotePTYBridgeAttachment(attachmentID: attachmentID, token: "immediate-output-token")
        }

        func writePTY(
            sessionID: String,
            attachmentID: String,
            attachmentToken: String,
            data: Data,
            completion: @escaping (Error?) -> Void
        ) {
            completion(nil)
        }
        func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}
    }

    private final class FloodPTYBridgeRPC: RemotePTYBridgeRPCClient, @unchecked Sendable {
        let detachSemaphore = DispatchSemaphore(value: 0)

        func attachBridgePTY(
            sessionID: String,
            attachmentID: String,
            cols: Int,
            rows: Int,
            command: String?,
            requireExisting: Bool,
            queue: DispatchQueue,
            onEvent: @escaping (RemotePTYBridgeEvent) -> Void
        ) throws -> RemotePTYBridgeAttachment {
            queue.async {
                let chunk = Data(repeating: 0x78, count: 64 * 1024)
                for _ in 0..<512 {
                    onEvent(.data(chunk))
                }
            }
            return RemotePTYBridgeAttachment(attachmentID: attachmentID, token: "flood-token")
        }

        func writePTY(
            sessionID: String,
            attachmentID: String,
            attachmentToken: String,
            data: Data,
            completion: @escaping (Error?) -> Void
        ) {
            completion(nil)
        }

        func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {
            detachSemaphore.signal()
        }
    }

    private final class DelayedOutputPTYBridgeRPC: RemotePTYBridgeRPCClient, @unchecked Sendable {
        let detachSemaphore = DispatchSemaphore(value: 0)

        private let attachStarted: DispatchSemaphore?
        private let attachGate: DispatchSemaphore?
        private let lock = NSLock()
        private var queue: DispatchQueue?
        private var onEvent: ((RemotePTYBridgeEvent) -> Void)?
        private var didEmit = false

        init(attachStarted: DispatchSemaphore? = nil, attachGate: DispatchSemaphore? = nil) {
            self.attachStarted = attachStarted
            self.attachGate = attachGate
        }

        func attachBridgePTY(
            sessionID: String,
            attachmentID: String,
            cols: Int,
            rows: Int,
            command: String?,
            requireExisting: Bool,
            queue: DispatchQueue,
            onEvent: @escaping (RemotePTYBridgeEvent) -> Void
        ) throws -> RemotePTYBridgeAttachment {
            attachStarted?.signal()
            if let attachGate {
                _ = attachGate.wait(timeout: .now() + 2)
            }
            lock.lock()
            self.queue = queue
            self.onEvent = onEvent
            lock.unlock()
            return RemotePTYBridgeAttachment(attachmentID: attachmentID, token: "delayed-token")
        }

        func writePTY(
            sessionID: String,
            attachmentID: String,
            attachmentToken: String,
            data: Data,
            completion: @escaping (Error?) -> Void
        ) {
            guard String(data: data, encoding: .utf8)?.contains("after-half-close-input") == true else {
                completion(nil)
                return
            }

            let emitQueue: DispatchQueue?
            let emitEvent: ((RemotePTYBridgeEvent) -> Void)?
            lock.lock()
            if didEmit {
                emitQueue = nil
                emitEvent = nil
            } else {
                didEmit = true
                emitQueue = queue
                emitEvent = onEvent
            }
            lock.unlock()

            emitQueue?.async {
                emitEvent?(.data(Data("after-half-close-output\n".utf8)))
                emitEvent?(.exit)
            }
            completion(nil)
        }

        func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {
            detachSemaphore.signal()
        }
    }

    private final class DeferredWriteCompletionPTYBridgeRPC: RemotePTYBridgeRPCClient, @unchecked Sendable {
        private let lock = NSLock()
        private var completions: [(Error?) -> Void] = []

        let firstWrite = DispatchSemaphore(value: 0)
        let secondWrite = DispatchSemaphore(value: 0)

        func attachBridgePTY(
            sessionID: String,
            attachmentID: String,
            cols: Int,
            rows: Int,
            command: String?,
            requireExisting: Bool,
            queue: DispatchQueue,
            onEvent: @escaping (RemotePTYBridgeEvent) -> Void
        ) throws -> RemotePTYBridgeAttachment {
            return RemotePTYBridgeAttachment(attachmentID: attachmentID, token: "deferred-token")
        }

        func writePTY(
            sessionID: String,
            attachmentID: String,
            attachmentToken: String,
            data: Data,
            completion: @escaping (Error?) -> Void
        ) {
            let writeCount: Int
            lock.lock()
            completions.append(completion)
            writeCount = completions.count
            lock.unlock()

            if writeCount == 1 {
                firstWrite.signal()
            } else if writeCount == 2 {
                secondWrite.signal()
            }
        }

        func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}

        func completeWrites() {
            let pending: [(Error?) -> Void]
            lock.lock()
            pending = completions
            completions.removeAll()
            lock.unlock()

            for completion in pending {
                completion(nil)
            }
        }
    }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private let commandSemaphore = DispatchSemaphore(value: 0)
        private(set) var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
            commandSemaphore.signal()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }

        func waitForCommand(timeout: TimeInterval, matching predicate: (String) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                lock.lock()
                let matched = commands.contains(where: predicate)
                lock.unlock()
                if matched {
                    return true
                }

                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    return false
                }
                if commandSemaphore.wait(timeout: .now() + remaining) == .timedOut {
                    return snapshot().contains(where: predicate)
                }
            }
        }
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func waitForProcess(_ process: Process, toHoldOpenFile path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var consecutiveHits = 0
        while Date() < deadline {
            guard process.isRunning else { return false }
            let result = runProcess(
                executablePath: "/usr/sbin/lsof",
                arguments: ["-n", "-p", "\(process.processIdentifier)", "-Fn"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 1
            )
            if result.status == 0, result.stdout.contains(path) {
                consecutiveHits += 1
                if consecutiveHits >= 2 {
                    return true
                }
            } else {
                consecutiveHits = 0
            }
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.05)
        }
        return false
    }

    private func cliTestEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        return environment
    }

    private func waitForSocketCommand(
        state: MockSocketServerState,
        timeout: TimeInterval,
        matching predicate: (String) -> Bool
    ) -> Bool {
        state.waitForCommand(timeout: timeout, matching: predicate)
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                status: -1,
                stdout: "",
                stderr: String(describing: error),
                timedOut: false
            )
        }
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    func testAgentHookLaunchEnvironmentDoesNotPersistPathOrShell() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("hook")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            return self.v2Response(
                id: line,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected command \(line)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        for key in [
            "ANTHROPIC_MODEL",
            "CLAUDE_CONFIG_DIR",
            "CMUX_CUSTOM_CLAUDE_PATH",
            "NODE_OPTIONS",
            "OPENCODE_CONFIG_DIR"
        ] {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated([
            "/usr/local/bin/codex",
            "--model",
            "gpt-5.4",
            "old prompt"
        ])
        environment["CMUX_AGENT_LAUNCH_CWD"] = "/tmp/repo"
        environment["CODEX_HOME"] = "/tmp/codex home"
        environment["PATH"] = "/tmp/custom-bin:/usr/bin"
        environment["SHELL"] = "/bin/zsh"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let data = try Data(contentsOf: storeURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let session = try XCTUnwrap(sessions[surfaceId] as? [String: Any])
        let launchCommand = try XCTUnwrap(session["launchCommand"] as? [String: Any])
        let persistedEnvironment = try XCTUnwrap(launchCommand["environment"] as? [String: String])
        XCTAssertEqual(persistedEnvironment, ["CODEX_HOME": "/tmp/codex home"])
    }

    func testCodexHookStopSetsRateLimitStatusFromTranscript() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let transcriptDirectory = try codexSessionDirectory(in: codexHome)
        let transcriptURL = transcriptDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.799Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 4:05 AM.","codex_error_info":"usage_limit_exceeded"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = codexHome.path

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-1","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Rate limit|")
            },
            "Expected Codex failure notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex rate limit") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex rate limit status, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsTypedCodexErrorEventAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-typed-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"Try again later.","codex_error_info":"server_overloaded"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-3","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-3","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Try again later.")
            },
            "Expected typed Codex error notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookStopFallsBackToDiscoveredTranscriptWhenProvidedPathUnavailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-stale-provided-path"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let transcriptDirectory = try codexSessionDirectory(in: codexHome)
        let discoveredTranscriptURL = transcriptDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","turn_id":"turn-stale-path","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-stale-path","last_agent_message":null}}
        """.write(to: discoveredTranscriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = codexHome.path

        let unavailableTranscriptURL = root.appendingPathComponent("missing-\(sessionId).jsonl")
        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-stale-path","transcript_path":"\(unavailableTranscriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Network error|Stream disconnected before completion.")
            },
            "Expected discovered transcript failure notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected discovered transcript failure status, saw \(state.commands)"
        )
    }

    func testCodexPromptSubmitRetiresPreviousMonitorLeaseForSameSession() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-leases-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-lease-dedupe"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        startMockServerAccepting(listenerFD: listenerFD, state: state, connectionLimit: 6) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String else {
                return "OK"
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: ["surfaces": [["id": surfaceId, "ref": surfaceId, "focused": true]]]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path

        let firstInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-one","cwd":"\(root.path)","hook_event_name":"UserPromptSubmit","prompt":"first"}
        """
        let firstResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: firstInput,
            timeout: 5
        )

        XCTAssertFalse(firstResult.timedOut, firstResult.stderr)
        XCTAssertEqual(firstResult.status, 0, firstResult.stderr)
        XCTAssertEqual(firstResult.stdout, "{}\n")
        XCTAssertTrue(
            waitForCodexMonitorActiveLeaseTurns(in: root, expected: ["turn-one"], timeout: 3),
            "Expected first prompt to leave one active monitor lease, saw \(codexMonitorActiveLeaseTurns(in: root))"
        )

        let secondInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-two","cwd":"\(root.path)","hook_event_name":"UserPromptSubmit","prompt":"second"}
        """
        let secondResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: secondInput,
            timeout: 5
        )

        XCTAssertFalse(secondResult.timedOut, secondResult.stderr)
        XCTAssertEqual(secondResult.status, 0, secondResult.stderr)
        XCTAssertEqual(secondResult.stdout, "{}\n")
        XCTAssertTrue(
            waitForCodexMonitorActiveLeaseTurns(in: root, expected: ["turn-two"], timeout: 3),
            "Expected a new turn to retire the prior Codex monitor lease, saw \(codexMonitorActiveLeaseTurns(in: root))"
        )
    }

    func testCodexHookStopTreatsCodexErrorInfoPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-payload-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-4","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"message":"Try again later.","codex_error_info":"server_overloaded"}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status from codex_error_info, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsStructuredCodexErrorInfoPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-structured-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-structured","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"message":"Try again later.","codex_error_info":{"code":"server_overloaded","retryable":true}}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected structured codex_error_info to publish high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsCamelCaseCodexErrorInfoPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-camel-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-5","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"message":"Try again later.","codexErrorInfo":"server_overloaded"}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status from camelCase codexErrorInfo, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsTypedHookPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-hook-type-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-6","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"type":"error","message":"Try again later."}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected typed hook payload to publish high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsExplicitErrorFieldAsFailureSignal() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-explicit-error-field"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-explicit-error","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"error":"quota exceeded"}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|quota exceeded")
            },
            "Expected explicit error field notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected explicit error field status, saw \(state.commands)"
        )
    }

    func testCodexHookStopDoesNotKeepOldTranscriptErrorAfterSuccessfulTurn() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-success"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}
        {"timestamp":"2026-04-25T07:56:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}],"phase":"final_answer"}}
        {"timestamp":"2026-04-25T07:56:00.100Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2","last_agent_message":"Done"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-2","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Done"}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Idle") &&
                    command.contains("--icon=pause.circle.fill") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected successful Codex turn to report Idle, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { $0.contains("set_status codex Codex rate limit") || $0.contains("#FF453A") },
            "Did not expect stale transcript error status, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                command.contains("notify_target") &&
                    (command.contains("Rate limit") || command.contains("Error") || command.contains("#FF453A"))
            },
            "Did not expect stale failure notification, saw \(state.commands)"
        )
    }

    func testCodexHookStopPrefersExplicitErrorPayloadOverHealthyTranscript() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-payload-beats-transcript"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:56:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}],"phase":"final_answer"}}
        {"timestamp":"2026-04-25T07:56:00.100Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-payload-error","last_agent_message":"Done"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-payload-error","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Partial answer","type":"error","message":"Try again later."}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Try again later.")
            },
            "Expected payload error notification to beat healthy transcript, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected payload error status to beat healthy transcript, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsCompletedTurnWithoutAssistantAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-no-final"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.600Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Previous turn completed."}]}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-no-final","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-no-final","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected no-final-response notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookStopDoesNotSynthesizeNoFinalResponseAfterScopedAssistantMessage() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-scoped-assistant"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-scoped-assistant","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.600Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-scoped-assistant","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-scoped-assistant","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Idle") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected scoped assistant reply to suppress no-final-response error, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                command.contains("Codex ended before sending a final response") || command.contains("--color=#FF453A")
            },
            "Did not expect no-final-response error after scoped assistant reply, saw \(state.commands)"
        )
    }

    func testCodexHookStopIgnoresUnscopedTranscriptErrorWithoutTurnEvidence() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-stale-unscoped-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-current","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Idle") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected stale unscoped error to leave Codex idle, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") || command.contains("--color=#FF453A")
            },
            "Did not expect stale unscoped error status, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorSetsErrorStatusFromCompletedTranscriptWithoutAssistant() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-no-final"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.600Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Previous turn completed."}]}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-monitor","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--session",
                sessionId,
                "--turn",
                "turn-monitor",
                "--transcript",
                transcriptURL.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected monitor to send no-final-response notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorReportsExplicitErrorBeforeTerminalCompletion() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-stream-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turnId":"turn-monitor-stream-error","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--session",
                sessionId,
                "--turn",
                "turn-monitor-stream-error",
                "--transcript",
                transcriptURL.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Network error|Stream disconnected before completion.")
            },
            "Expected monitor to send stream error notification before terminal completion, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex network error status, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorNotifiesOnRequestUserInput() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-user-input"
        let turnId = "turn-monitor-user-input"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\(turnId)","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.700Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"call-plan-question","turn_id":"\(turnId)","questions":[{"id":"demo_path","header":"Demo","question":"Which demo path should I use?","options":[{"label":"Plan","description":"Show plan mode"}]}]}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        _ = startMockServerSignal(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "hooks", "codex", "monitor",
            "--workspace",
            workspaceId,
            "--surface",
            surfaceId,
            "--session",
            sessionId,
            "--turn",
            turnId,
            "--transcript",
            transcriptURL.path,
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        defer {
            if process.isRunning {
                process.terminate()
                _ = exitSignal.wait(timeout: .now() + 1)
            }
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        XCTAssertTrue(
            waitForProcess(process, toHoldOpenFile: transcriptURL.path, timeout: 2),
            "Monitor did not start watching the request_user_input transcript"
        )
        XCTAssertTrue(
            waitForSocketCommand(state: state, timeout: 5) { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Waiting|Which demo path should I use?")
            },
            "Expected monitor to send Codex input notification, saw \(state.snapshot())"
        )
        XCTAssertTrue(
            waitForSocketCommand(state: state, timeout: 5) { command in
                command.contains("set_status codex Codex needs input") &&
                    command.contains("--icon=bell.fill") &&
                    command.contains("--color=#4C8DFF") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex input status, saw \(state.snapshot())"
        )
        XCTAssertTrue(process.isRunning, "Monitor should keep watching the turn after publishing input notification")
    }

    func testCodexHookMonitorNotifiesOnResponseItemRequestUserInput() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-response-item")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-response-item"
        let turnId = "turn-monitor-response-item"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"turn_context","payload":{"turn_id":"\(turnId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.700Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\\"questions\\":[{\\"id\\":\\"demo_type\\",\\"header\\":\\"Demo Type\\",\\"question\\":\\"What kind of demo plan should I create?\\",\\"options\\":[{\\"label\\":\\"Product walkthrough (Recommended)\\",\\"description\\":\\"A timed agenda.\\"}]}]}","call_id":"call-plan-function"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        _ = startMockServerSignal(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "hooks", "codex", "monitor",
            "--workspace",
            workspaceId,
            "--surface",
            surfaceId,
            "--session",
            sessionId,
            "--turn",
            turnId,
            "--transcript",
            transcriptURL.path,
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        defer {
            if process.isRunning {
                process.terminate()
                _ = exitSignal.wait(timeout: .now() + 1)
            }
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        XCTAssertTrue(
            waitForProcess(process, toHoldOpenFile: transcriptURL.path, timeout: 2),
            "Monitor did not start watching the response_item request_user_input transcript"
        )
        XCTAssertTrue(
            waitForSocketCommand(state: state, timeout: 5) { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Waiting|What kind of demo plan should I create?")
            },
            "Expected monitor to send Codex input notification from response_item, saw \(state.snapshot())"
        )
        XCTAssertTrue(
            waitForSocketCommand(state: state, timeout: 5) { command in
                command.contains("set_status codex Codex needs input") &&
                    command.contains("--icon=bell.fill") &&
                    command.contains("--color=#4C8DFF") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex input status, saw \(state.snapshot())"
        )
        XCTAssertTrue(process.isRunning, "Monitor should keep watching the turn after publishing input notification")
    }

    func testCodexHookMonitorReResolvesUnavailableTranscriptPath() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-reresolve"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let transcriptDirectory = try codexSessionDirectory(in: codexHome)
        let staleTranscriptURL = root.appendingPathComponent("missing-rollout-\(sessionId).jsonl")
        let transcriptURL = transcriptDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-monitor-reresolve","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-monitor-reresolve","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = codexHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--session",
                sessionId,
                "--turn",
                "turn-monitor-reresolve",
                "--transcript",
                staleTranscriptURL.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected monitor to recover from stale transcript path, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex error status after re-resolving transcript path, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorIgnoresUnscopedTerminalForTurnScopedMonitor() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-turn-scoped"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Old unscoped turn completed."}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServerSignal(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "hooks", "codex", "monitor",
            "--workspace",
            workspaceId,
            "--surface",
            surfaceId,
            "--session",
            sessionId,
            "--turn",
            "turn-monitor-scoped",
            "--transcript",
            transcriptURL.path,
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        XCTAssertTrue(
            waitForProcess(process, toHoldOpenFile: transcriptURL.path, timeout: 2),
            "Monitor did not start watching the initial transcript before scoped append"
        )
        XCTAssertTrue(process.isRunning, "Monitor exited on an unscoped terminal event before the scoped turn wrote an error")

        let appendHandle = try FileHandle(forWritingTo: transcriptURL)
        try appendHandle.seekToEnd()
        appendHandle.write(Data("\n".utf8))
        appendHandle.write(Data("""
        {"timestamp":"2026-04-25T07:55:30.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-monitor-scoped","started_at":1777107530}}
        {"timestamp":"2026-04-25T07:55:30.100Z","type":"event_msg","payload":{"type":"error","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        """.utf8))
        try appendHandle.close()

        let serverTimedOut = serverHandled.wait(timeout: .now() + 5) == .timedOut
        let timedOut = exitSignal.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(serverTimedOut, "Timed out waiting for mock socket command. stderr: \(stderr)")
        XCTAssertFalse(timedOut, stderr)
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertEqual(stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Network error|Stream disconnected before completion.")
            },
            "Expected monitor to ignore old unscoped terminal event and report scoped stream error, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish scoped Codex network error status, saw \(state.commands)"
        )
    }

    func testPTYBridgeFlushesReadyBeforeImmediateExit() throws {
        let rpcClient = ImmediateExitPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = RemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-short-lived",
            attachmentID: "attachment-short-lived",
            command: "printf done",
            requireExisting: true,
            strings: AppRemotePTYBridgeStrings()
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
            "client_pid": Int(getpid()),
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\n", to: fd))

        let responseData = try readUntilEOF(from: fd, timeout: 2)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let responseText = String(data: responseData, encoding: .utf8) ?? ""
        let responseLines = responseText.split(separator: "\n").map(String.init)
        let firstPayload = try XCTUnwrap(responseLines.first?.data(using: .utf8))
        let firstJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstPayload, options: []) as? [String: Any]
        )
        XCTAssertEqual(firstJSON["type"] as? String, "ready", "Expected ready frame first, saw \(responseText)")
        XCTAssertEqual(rpcClient.attachCalls.count, 1)
        XCTAssertEqual(rpcClient.attachCalls.first?.sessionID, "session-short-lived")
        XCTAssertEqual(rpcClient.attachCalls.first?.attachmentID, "attachment-short-lived")
        XCTAssertEqual(rpcClient.attachCalls.first?.command, "printf done")
        XCTAssertEqual(rpcClient.attachCalls.first?.requireExisting, true)
    }

    func testPTYBridgeBuffersOutputUntilReadyFrame() throws {
        let rpcClient = ImmediateOutputThenExitPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = RemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-early-output",
            attachmentID: "attachment-early-output",
            command: nil,
            requireExisting: true,
            strings: AppRemotePTYBridgeStrings()
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\n", to: fd))

        let responseData = try readUntilEOF(from: fd, timeout: 2)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let responseText = String(data: responseData, encoding: .utf8) ?? ""
        let responseLines = responseText.split(separator: "\n", maxSplits: 1).map(String.init)
        let firstPayload = try XCTUnwrap(responseLines.first?.data(using: .utf8))
        let firstJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstPayload, options: []) as? [String: Any]
        )
        XCTAssertEqual(firstJSON["type"] as? String, "ready", responseText)
        XCTAssertTrue(responseText.contains("early-output"), responseText)
    }

    func testPTYBridgeForwardsInputWithoutWaitingForWriteCompletion() throws {
        let rpcClient = DeferredWriteCompletionPTYBridgeRPC()
        let server = RemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-input-completion",
            attachmentID: "attachment-input-completion",
            command: nil,
            requireExisting: false,
            strings: AppRemotePTYBridgeStrings()
        ) {}
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            rpcClient.completeWrites()
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\n", to: fd))

        let readyLine = try readLine(from: fd, timeout: 2)
        XCTAssertTrue(readyLine.contains("\"ready\""), readyLine)

        XCTAssertTrue(writeAll("a", to: fd))
        XCTAssertEqual(rpcClient.firstWrite.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(writeAll("b", to: fd))
        XCTAssertEqual(
            rpcClient.secondWrite.wait(timeout: .now() + 1.0),
            .success,
            "Bridge input forwarding should not wait for the prior pty.write response"
        )
        rpcClient.completeWrites()
    }

    func testPTYBridgeStopRetainsServerUntilCleanupRuns() throws {
        let rpcClient = ImmediateExitPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        var server: RemotePTYBridgeServer? = RemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-stop-retain",
            attachmentID: "attachment-stop-retain",
            command: nil,
            requireExisting: false,
            strings: AppRemotePTYBridgeStrings()
        ) {
            stopped.signal()
        }
        guard let endpoint = try server?.start() else {
            return XCTFail("Failed to start PTY bridge server")
        }
        XCTAssertGreaterThan(endpoint.port, 0)

        server?.stop()
        server = nil

        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
    }

    func testPTYBridgeKeepsOutputOpenAfterClientHalfClose() throws {
        let rpcClient = DelayedOutputPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = RemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-half-close",
            attachmentID: "attachment-half-close",
            command: nil,
            requireExisting: false,
            strings: AppRemotePTYBridgeStrings()
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\nafter-half-close-input", to: fd))
        XCTAssertEqual(Darwin.shutdown(fd, SHUT_WR), 0)

        let responseData = try readUntilEOF(from: fd, timeout: 2)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let responseText = String(data: responseData, encoding: .utf8) ?? ""
        XCTAssertTrue(responseText.contains("\"ready\""), responseText)
        XCTAssertTrue(responseText.contains("after-half-close-output"), responseText)
        XCTAssertEqual(rpcClient.detachSemaphore.wait(timeout: .now() + 0.1), .timedOut)
    }

    func testPTYBridgeKeepsOutputOpenAfterClientHalfCloseWithoutPID() throws {
        let rpcClient = DelayedOutputPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = RemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-half-close-no-pid",
            attachmentID: "attachment-half-close-no-pid",
            command: nil,
            requireExisting: false,
            strings: AppRemotePTYBridgeStrings()
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\nafter-half-close-input", to: fd))
        XCTAssertEqual(Darwin.shutdown(fd, SHUT_WR), 0)

        let responseData = try readUntilEOF(from: fd, timeout: 2)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let responseText = String(data: responseData, encoding: .utf8) ?? ""
        XCTAssertTrue(responseText.contains("\"ready\""), responseText)
        XCTAssertTrue(responseText.contains("after-half-close-output"), responseText)
        XCTAssertEqual(rpcClient.detachSemaphore.wait(timeout: .now() + 0.1), .timedOut)
    }

    func testPTYBridgeDefersHalfCloseUntilAttachCompletes() throws {
        let attachStarted = DispatchSemaphore(value: 0)
        let attachGate = DispatchSemaphore(value: 0)
        let rpcClient = DelayedOutputPTYBridgeRPC(attachStarted: attachStarted, attachGate: attachGate)
        let stopped = DispatchSemaphore(value: 0)
        let server = RemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-half-close-before-attach",
            attachmentID: "attachment-half-close-before-attach",
            command: nil,
            requireExisting: false,
            strings: AppRemotePTYBridgeStrings()
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
            "client_pid": Int(getpid()),
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\nafter-half-close-input", to: fd))
        XCTAssertEqual(attachStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(Darwin.shutdown(fd, SHUT_WR), 0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        attachGate.signal()

        let responseData = try readUntilEOF(from: fd, timeout: 2)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let responseText = String(data: responseData, encoding: .utf8) ?? ""
        XCTAssertTrue(responseText.contains("\"ready\""), responseText)
        XCTAssertTrue(responseText.contains("after-half-close-output"), responseText)
        XCTAssertEqual(rpcClient.detachSemaphore.wait(timeout: .now() + 0.1), .timedOut)
    }

    func testPTYBridgeDetachesWhenClientSocketClosesAfterAttach() throws {
        let rpcClient = DelayedOutputPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = RemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-client-close",
            attachmentID: "attachment-client-close",
            command: nil,
            requireExisting: false,
            strings: AppRemotePTYBridgeStrings()
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
            "client_pid": Int(Int32.max),
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            Darwin.close(fd)
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\n", to: fd))
        let readyLine = try readLine(from: fd, timeout: 2)
        XCTAssertTrue(readyLine.contains("\"ready\""), readyLine)

        Darwin.close(fd)
        XCTAssertEqual(rpcClient.detachSemaphore.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
    }

    func testPTYBridgeClosesBackpressuredOutput() throws {
        let rpcClient = FloodPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = RemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-output-flood",
            attachmentID: "attachment-output-flood",
            command: nil,
            requireExisting: false,
            strings: AppRemotePTYBridgeStrings()
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\n", to: fd))

        XCTAssertEqual(rpcClient.detachSemaphore.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
    }

    private func codexSessionDirectory(in codexHome: URL, date: Date = Date()) throws -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = try XCTUnwrap(components.year)
        let month = try XCTUnwrap(components.month)
        let day = try XCTUnwrap(components.day)
        let directory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix socket"]
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind Unix socket"]
            )
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on Unix socket"]
            )
        }

        return fd
    }

    private func connectLoopbackTCP(port: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_INET)")
        }
        do {
            try configureSocketTimeout(fd, option: SO_RCVTIMEO, timeout: 2)
            try configureSocketTimeout(fd, option: SO_SNDTIMEO, timeout: 2)

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let connectResult = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                throw posixError("connect(127.0.0.1:\(port))")
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func readUntilEOF(from fd: Int32, timeout: TimeInterval) throws -> Data {
        try configureSocketTimeout(fd, option: SO_RCVTIMEO, timeout: timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0 {
                return data
            }
            if errno == EINTR {
                continue
            }
            throw posixError("read bridge response")
        }
    }

    private func readLine(from fd: Int32, timeout: TimeInterval) throws -> String {
        try configureSocketTimeout(fd, option: SO_RCVTIMEO, timeout: timeout)
        var data = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count > 0 {
                if byte[0] == 0x0A {
                    return String(data: data, encoding: .utf8) ?? ""
                }
                data.append(byte[0])
                continue
            }
            if count == 0 {
                return String(data: data, encoding: .utf8) ?? ""
            }
            if errno == EINTR {
                continue
            }
            throw posixError("read bridge line")
        }
    }

    private func configureSocketTimeout(_ fd: Int32, option: Int32, timeout: TimeInterval) throws {
        let normalizedTimeout = max(timeout, 0)
        let seconds = floor(normalizedTimeout)
        let microseconds = (normalizedTimeout - seconds) * 1_000_000
        var socketTimeout = timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds.rounded()))
        let result = withUnsafePointer(to: &socketTimeout) { ptr in
            Darwin.setsockopt(
                fd,
                SOL_SOCKET,
                option,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw posixError("setsockopt")
        }
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }

    private func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli mock socket handled")
        runMockServer(listenerFD: listenerFD, state: state, onHandled: {
            handled.fulfill()
        }, handler: handler)
        return handled
    }

    private func startMockServerSignal(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        runMockServer(listenerFD: listenerFD, state: state, onHandled: {
            handled.signal()
        }, handler: handler)
        return handled
    }

    private func startMockServerAccepting(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionLimit: Int,
        handler: @escaping @Sendable (String) -> String
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var accepted = 0
            while accepted < connectionLimit {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                accepted += 1

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(clientFD) }
                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)

                    while true {
                        let count = Darwin.read(clientFD, &buffer, buffer.count)
                        if count < 0 {
                            if errno == EINTR { continue }
                            return
                        }
                        if count == 0 { return }
                        pending.append(buffer, count: count)

                        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                            let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                            pending.removeSubrange(0...newlineRange.lowerBound)
                            guard let line = String(data: lineData, encoding: .utf8) else { continue }
                            state.append(line)
                            guard self.writeAll(handler(line) + "\n", to: clientFD) else { return }
                        }
                    }
                }
            }
        }
    }

    private func runMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        onHandled: @escaping @Sendable () -> Void,
        handler: @escaping @Sendable (String) -> String
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                onHandled()
                return
            }
            defer {
                Darwin.close(clientFD)
                onHandled()
            }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)

            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    state.append(line)
                    guard self.writeAll(handler(line) + "\n", to: clientFD) else { return }
                }
            }
        }
    }

    private func writeAll(_ string: String, to fd: Int32) -> Bool {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                return false
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            return false
        }
        return true
    }

    private func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result {
            payload["result"] = result
        }
        if let error {
            payload["error"] = error
        }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private func codexMonitorActiveLeaseTurns(in root: URL) -> [String] {
        let directory = root.appendingPathComponent("codex-monitor-leases", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url),
                  let lease = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return nil
            }
            if let retiredAt = lease["retiredAt"], !(retiredAt is NSNull) {
                return nil
            }
            return lease["turnId"] as? String
        }.sorted()
    }

    private func waitForCodexMonitorActiveLeaseTurns(
        in root: URL,
        expected: [String],
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if codexMonitorActiveLeaseTurns(in: root) == expected.sorted() {
                return true
            }
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.05)
        }
        return codexMonitorActiveLeaseTurns(in: root) == expected.sorted()
    }

    @MainActor
    func testNotifyWithWorkspaceHandleKeepsCallerSurfaceFallback() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let currentWorkspace = "11111111-1111-1111-1111-111111111111"
        let currentSurface = "22222222-2222-2222-2222-222222222222"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                if method == "workspace.list" { return self.v2Response(id: id, ok: true, result: ["workspaces": [["id": currentWorkspace, "index": 1]]]) }
                if method == "notification.create_for_caller" {
                    let params = payload["params"] as? [String: Any] ?? [:]
                    XCTAssertEqual(params["preferred_workspace_id"] as? String, currentWorkspace)
                    XCTAssertEqual(params["preferred_surface_id"] as? String, staleSurface)
                    XCTAssertEqual(params["prefer_tty"] as? Bool, false)
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: ["workspace_id": currentWorkspace, "surface_id": currentSurface]
                    )
                }
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }

            return "ERROR: Unexpected command \(line)"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["TMUX"] = "/tmp/tmux-current,123,0"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--workspace", "1"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create_for_caller\"") },
            "Expected notify to use single-call caller notification path, saw \(state.commands)"
        )
    }

    @MainActor
    func testNotifyWithWorkspaceHandlePreservesSyncTargetValidation() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-handle")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                switch method {
                case "workspace.list":
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "workspaces": [
                                ["id": workspaceId, "index": 1]
                            ]
                        ]
                    )
                default:
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                    )
                }
            }

            if line.hasPrefix("notify_target \(workspaceId) \(staleSurface) ") {
                return "ERROR: Panel not found"
            }
            if line.hasPrefix("notify_target_async ") {
                return "OK"
            }
            return "ERROR: Unexpected command \(line)"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--workspace", "1", "--surface", staleSurface, "--title", "Mixed"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("ERROR: Panel not found"), result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.hasPrefix("notify_target \(workspaceId) \(staleSurface) ") },
            "Expected notify to use synchronous target validation, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { $0.hasPrefix("notify_target_async ") },
            "Expected no async target dispatch for mixed handles, saw \(state.commands)"
        )
    }

    @MainActor
    func testTriggerFlashFallsBackFromStaleCallerWorkspaceAndSurfaceIDs() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("flash")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let currentWorkspace = "11111111-1111-1111-1111-111111111111"
        let currentSurface = "22222222-2222-2222-2222-222222222222"
        let staleWorkspace = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "surface.list":
                let workspaceId = params["workspace_id"] as? String
                if workspaceId == staleWorkspace {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "Workspace not found"]
                    )
                }
                if workspaceId == currentWorkspace {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": currentSurface,
                                    "ref": "surface:1",
                                    "index": 0,
                                    "focused": true
                                ]
                            ]
                        ]
                    )
                }
            case "workspace.current":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": currentWorkspace]
                )
            case "surface.trigger_flash":
                let workspaceId = params["workspace_id"] as? String
                let surfaceId = params["surface_id"] as? String
                if workspaceId == currentWorkspace, surfaceId == currentSurface {
                    return self.v2Response(id: id, ok: true, result: [:])
                }
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = staleWorkspace
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["trigger-flash"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == currentWorkspace
                    && (params["surface_id"] as? String) == currentSurface
            },
            "Expected surface.trigger_flash to use current workspace and surface, saw \(state.commands)"
        )
    }

    @MainActor
    func testSSHCommandCreatesConfiguresAndSelectsRemoteWorkspaceViaCLI() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:7"
        let windowID = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            switch method {
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "window_id": windowID,
                    ]
                )
            case "workspace.rename":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.remote.configure":
                let params = payload["params"] as? [String: Any] ?? [:]
                let autoConnect = (params["auto_connect"] as? Bool) ?? true
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "remote": [
                            "enabled": true,
                            "state": autoConnect ? "connecting" : "disconnected",
                        ],
                    ]
                )
            case "workspace.select":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--name", "SSH Workspace",
                "--port", "2222",
                "--identity", "/Users/test/.ssh/id_ed25519",
                "--ssh-option", "ControlPath /tmp/cmux-ssh-%C",
                "--ssh-option", "StrictHostKeyChecking=accept-new",
                "--window", windowID,
                "cmux-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK workspace=\(workspaceRef) target=cmux-macmini state=disconnected\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["workspace.create", "workspace.rename", "workspace.remote.configure", "workspace.select"]
        )

        let createParams = try XCTUnwrap(requests[0]["params"] as? [String: Any])
        XCTAssertEqual(createParams["window_id"] as? String, windowID)
        let initialCommand = try XCTUnwrap(createParams["initial_command"] as? String)
        XCTAssertFalse(initialCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let renameParams = try XCTUnwrap(requests[1]["params"] as? [String: Any])
        XCTAssertEqual(renameParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(renameParams["title"] as? String, "SSH Workspace")

        let configureParams = try XCTUnwrap(requests[2]["params"] as? [String: Any])
        XCTAssertEqual(configureParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(configureParams["destination"] as? String, "cmux-macmini")
        XCTAssertEqual(configureParams["port"] as? Int, 2222)
        XCTAssertEqual(configureParams["identity_file"] as? String, "/Users/test/.ssh/id_ed25519")
        XCTAssertEqual(configureParams["local_socket_path"] as? String, socketPath)
        XCTAssertEqual(configureParams["auto_connect"] as? Bool, false)
        let relayPort = try XCTUnwrap(configureParams["relay_port"] as? Int)
        XCTAssertGreaterThan(relayPort, 0)
        let relayID = try XCTUnwrap(configureParams["relay_id"] as? String)
        XCTAssertFalse(relayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let relayToken = try XCTUnwrap(configureParams["relay_token"] as? String)
        XCTAssertEqual(relayToken.count, 64)
        let foregroundAuthToken = try XCTUnwrap(configureParams["foreground_auth_token"] as? String)
        XCTAssertFalse(foregroundAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let terminalStartupCommand = try XCTUnwrap(configureParams["terminal_startup_command"] as? String)
        XCTAssertFalse(terminalStartupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        XCTAssertTrue(sshOptions.contains("ControlMaster=auto"))
        XCTAssertTrue(sshOptions.contains("ControlPersist=600"))
        XCTAssertTrue(sshOptions.contains("ControlPath /tmp/cmux-ssh-%C"))
        XCTAssertTrue(sshOptions.contains("StrictHostKeyChecking=accept-new"))

        // `cmux ssh` should land the user in the new SSH workspace immediately.
        let selectParams = try XCTUnwrap(requests[3]["params"] as? [String: Any])
        XCTAssertEqual(selectParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(selectParams["window_id"] as? String, windowID)
    }

    @MainActor
    func testSSHCommandDoesNotDeferReconnectWhenWhitespaceControlMasterDisablesMultiplexing() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-controlmaster-no")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:9"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            switch method {
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                    ]
                )
            case "workspace.remote.configure":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "remote": [
                            "enabled": true,
                            "state": "connecting",
                        ],
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--no-focus",
                "--port", "2222",
                "--ssh-option", "ControlMaster no",
                "--ssh-option", "ControlPath /tmp/cmux-ssh-%C",
                "cmux-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK workspace=\(workspaceRef) target=cmux-macmini state=connecting\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["workspace.create", "workspace.remote.configure"]
        )

        let configureParams = try XCTUnwrap(requests[1]["params"] as? [String: Any])
        XCTAssertEqual(configureParams["auto_connect"] as? Bool, true)
        XCTAssertNil(configureParams["foreground_auth_token"])
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        XCTAssertTrue(sshOptions.contains("ControlMaster no"))
        XCTAssertTrue(sshOptions.contains("ControlPath /tmp/cmux-ssh-%C"))
    }

    @MainActor
    func testNotifyPrefersCallerTTYOverFocusedSurfaceWhenCallerIDsAreStale() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerTTY = "/dev/ttys777"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"
        let focusedSurface = "33333333-3333-3333-3333-333333333333"
        let staleWorkspace = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "ERROR: Unexpected command \(line)"
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "notification.create_for_caller":
                XCTAssertEqual(params["preferred_workspace_id"] as? String, staleWorkspace)
                XCTAssertEqual(params["preferred_surface_id"] as? String, staleSurface)
                XCTAssertEqual(params["caller_tty"] as? String, "ttys777")
                XCTAssertEqual(params["prefer_tty"] as? Bool, false)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": callerSurface]
                )
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = staleWorkspace
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_TTY_NAME"] = callerTTY
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create_for_caller\"") },
            "Expected notify to use single-call caller notification path, saw \(state.commands)"
        )
    }

    @MainActor
    func testNotifyInTmuxPrefersCallerTTYOverStaleValidSurfaceID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-tmux-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerTTY = "/dev/ttys777"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"
        let staleSurface = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "ERROR: Unexpected command \(line)"
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "notification.create_for_caller":
                XCTAssertEqual(params["preferred_workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["preferred_surface_id"] as? String, staleSurface)
                XCTAssertEqual(params["caller_tty"] as? String, "ttys777")
                XCTAssertEqual(params["prefer_tty"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": callerSurface]
                )
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_TTY_NAME"] = callerTTY
        environment["TMUX"] = "/tmp/tmux-current,123,0"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create_for_caller\"") },
            "Expected notify to use single-call caller notification path in tmux, saw \(state.commands)"
        )
    }

    @MainActor
    func testTriggerFlashPrefersCallerTTYOverFocusedSurfaceWhenCallerIDsAreStale() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("flash-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerTTY = "/dev/ttys777"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"
        let focusedSurface = "33333333-3333-3333-3333-333333333333"
        let staleWorkspace = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "surface.list":
                let requestedWorkspace = params["workspace_id"] as? String
                if requestedWorkspace == staleWorkspace {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "Workspace not found"]
                    )
                }
                if requestedWorkspace == workspaceId {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": callerSurface,
                                    "ref": "surface:1",
                                    "index": 0,
                                    "focused": false
                                ],
                                [
                                    "id": focusedSurface,
                                    "ref": "surface:2",
                                    "index": 1,
                                    "focused": true
                                ]
                            ]
                        ]
                    )
                }
            case "workspace.current":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId]
                )
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "count": 2,
                        "terminals": [
                            [
                                "workspace_id": workspaceId,
                                "surface_id": callerSurface,
                                "tty": callerTTY
                            ],
                            [
                                "workspace_id": workspaceId,
                                "surface_id": focusedSurface,
                                "tty": "/dev/ttys778"
                            ]
                        ]
                    ]
                )
            case "surface.trigger_flash":
                let requestedWorkspace = params["workspace_id"] as? String
                let requestedSurface = params["surface_id"] as? String
                if requestedWorkspace == workspaceId, requestedSurface == callerSurface {
                    return self.v2Response(id: id, ok: true, result: [:])
                }
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = staleWorkspace
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_TTY_NAME"] = callerTTY
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["trigger-flash"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == callerSurface
            },
            "Expected surface.trigger_flash to use caller tty surface, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == focusedSurface
            },
            "Focused surface should not win over caller tty, saw \(state.commands)"
        )
    }

    @MainActor
    func testTriggerFlashInTmuxPrefersCallerTTYOverStaleValidSurfaceID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("flash-tmux-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerTTY = "/dev/ttys777"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"
        let staleSurface = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "surface.list":
                let requestedWorkspace = params["workspace_id"] as? String
                if requestedWorkspace == workspaceId {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": callerSurface,
                                    "ref": "surface:1",
                                    "index": 0,
                                    "focused": false
                                ],
                                [
                                    "id": staleSurface,
                                    "ref": "surface:2",
                                    "index": 1,
                                    "focused": true
                                ]
                            ]
                        ]
                    )
                }
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "count": 2,
                        "terminals": [
                            [
                                "workspace_id": workspaceId,
                                "surface_id": callerSurface,
                                "tty": callerTTY
                            ],
                            [
                                "workspace_id": workspaceId,
                                "surface_id": staleSurface,
                                "tty": "/dev/ttys778"
                            ]
                        ]
                    ]
                )
            case "surface.trigger_flash":
                let requestedWorkspace = params["workspace_id"] as? String
                let requestedSurface = params["surface_id"] as? String
                if requestedWorkspace == workspaceId,
                   (requestedSurface == callerSurface || requestedSurface == staleSurface) {
                    return self.v2Response(id: id, ok: true, result: [:])
                }
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_TTY_NAME"] = callerTTY
        environment["TMUX"] = "/tmp/tmux-current,123,0"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["trigger-flash"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == callerSurface
            },
            "Expected trigger-flash to use caller tty surface in tmux, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == staleSurface
            },
            "Stale env surface should not win inside tmux, saw \(state.commands)"
        )
    }
}
