@preconcurrency import XCTest
import Darwin
import Foundation

final class BashShellIntegrationHandoffTests: XCTestCase {
    func testShellIntegrationRelayReportTTYUsesWorkspaceIDInBash() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-report-tty-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_NAME=ttys888
            _cmux_report_tty_via_relay
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys888","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            result.stdout
        )
    }

    func testShellIntegrationRelayPreexecWorksBeforeSurfaceIDExistsInBash() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-preexec-no-surface-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_NAME=ttys889
            _CMUX_TTY_REPORTED=0
            _cmux_preexec_command "python3 -m http.server 8899"
            for _cmux_i in $(seq 1 20); do
              [ -s "\(logPath.path)" ] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "",
            ]
        )

        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys889"}"#),
            result.stdout
        )
        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"command"}"#),
            result.stdout
        )
        XCTAssertFalse(result.stdout.contains(#""surface_id""#), result.stdout)
    }

    func testShellIntegrationRelayPromptRefreshUsesRefreshReasonInBashWithoutPromptNoise() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-prompt-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=-999
            _cmux_prompt_command
            for _cmux_i in $(seq 1 20); do
              [ -s "\(logPath.path)" ] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertFalse(result.stderr.contains("_cmux_report_tmux_state"), result.stderr)
        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            result.stdout
        )
    }

    func testBashNoGitWatchSkipsHeadTrackingAndPRClear() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-no-git-watch-\(UUID().uuidString)")
        let repoA = root.appendingPathComponent("repo-a", isDirectory: true)
        let repoB = root.appendingPathComponent("repo-b", isDirectory: true)
        let logPath = root.appendingPathComponent("send.log", isDirectory: false)
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            mkdir -p "\(repoA.path)/.git" "\(repoB.path)/.git"
            printf '%s\\n' 'ref: refs/heads/main' > "\(repoA.path)/.git/HEAD"
            printf '%s\\n' 'ref: refs/heads/feature' > "\(repoB.path)/.git/HEAD"
            : > "\(logPath.path)"
            _cmux_send() { printf '%s\\n' "$1" >> "\(logPath.path)"; }
            cd "\(repoA.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_GIT_HEAD_LAST_PWD="$PWD"
            _CMUX_GIT_HEAD_PATH="$PWD/.git/HEAD"
            _CMUX_GIT_HEAD_SIGNATURE="$(_cmux_git_head_signature "$_CMUX_GIT_HEAD_PATH")"
            printf '%s\\n' 'ref: refs/heads/old-cleared' > "$_CMUX_GIT_HEAD_PATH"
            cd "\(repoB.path)"
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_LAST_PR_ACTION="checkout"
            _CMUX_LAST_PR_TARGET="feature"
            _cmux_prompt_command
            printf 'HEAD_PATH=%s\\n' "$_CMUX_GIT_HEAD_PATH"
            printf 'HEAD_LAST_PWD=%s\\n' "$_CMUX_GIT_HEAD_LAST_PWD"
            printf 'LAST_PR_ACTION=%s\\n' "$_CMUX_LAST_PR_ACTION"
            printf 'LOG<<EOF\\n'
            cat "\(logPath.path)"
            printf 'EOF\\n'
            """,
            extraEnvironment: [
                "CMUX_NO_GIT_WATCH": "1",
                "CMUX_SOCKET_PATH": socketPath.path,
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertFalse(result.stdout.contains(repoA.appendingPathComponent(".git/HEAD").path), result.stdout)
        XCTAssertTrue(result.stdout.contains("HEAD_PATH=\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("HEAD_LAST_PWD=\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("LAST_PR_ACTION=\n"), result.stdout)
        XCTAssertFalse(result.stdout.contains("clear_pr"), result.stdout)
        XCTAssertFalse(result.stdout.contains("report_pr_action"), result.stdout)
    }

    func testBashFireAndForgetSocketReportsDoNotEmitJobStatus() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-background-reports-\(UUID().uuidString)")
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_send() { :; }
            _CMUX_TTY_NAME=ttys999
            _CMUX_TTY_REPORTED=0
            _cmux_report_tty_once
            _CMUX_SHELL_ACTIVITY_LAST=""
            _cmux_report_shell_activity_state running
            _cmux_ports_kick command
            _CMUX_LAST_PR_ACTION="checkout"
            _CMUX_LAST_PR_TARGET="feature"
            _cmux_emit_pr_command_hint
            _CMUX_TTY_REPORTED=1
            _CMUX_SHELL_ACTIVITY_LAST=running
            _CMUX_PWD_LAST_PWD="/not-the-current-directory"
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _cmux_prompt_command
            :
            """,
            extraEnvironment: [
                "CMUX_NO_GIT_WATCH": "1",
                "CMUX_SOCKET_PATH": socketPath.path,
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertNil(
            result.stderr.range(of: #"(?m)^\[[0-9]+\][^\n]*$"#, options: .regularExpression),
            result.stderr
        )
        XCTAssertFalse(result.stderr.contains("Done"), result.stderr)
    }

    func testBashRelayFireAndForgetReportsDoNotEmitJobStatus() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-background-reports-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let cmuxStubPath = binDir.appendingPathComponent("cmux", isDirectory: false)
        try writeExecutableScript(
            at: cmuxStubPath,
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_PORTS_LAST_RUN=0
            _cmux_ports_kick command
            for _cmux_i in $(seq 1 50); do
              [ -s "\(logPath.path)" ] && break
              sleep 0.02
            done
            cat "\(logPath.path)"
            :
            """,
            extraEnvironment: [
                "CMUX_BUNDLED_CLI_PATH": cmuxStubPath.path,
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"command","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            result.stdout
        )
        XCTAssertNil(
            result.stderr.range(of: #"(?m)^\[[0-9]+\][^\n]*$"#, options: .regularExpression),
            result.stderr
        )
        XCTAssertFalse(result.stderr.contains("Done"), result.stderr)
    }

    func testBashNoPullRequestWatchSkipsLegacyGhPRProbe() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-no-pr-watch-\(UUID().uuidString)")
        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        let fakeBinURL = root.appendingPathComponent("fake-bin", isDirectory: true)
        let markerURL = root.appendingPathComponent("gh-pr-invoked", isDirectory: false)
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: repoURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        try "ref: refs/heads/issue-2746-rate-limit\n".write(
            to: repoURL.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try writeExecutableScript(
            at: fakeBinURL.appendingPathComponent("gh"),
            contents: """
            #!/bin/sh
            printf invoked > "$CMUX_GH_MARKER"
            printf '2746\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/2746\\n'
            """
        )
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_send() { :; }
            _cmux_report_pr_for_path "\(repoURL.path)" || true
            [[ -e "\(markerURL.path)" ]] && printf 'MARKER=1\\n' || printf 'MARKER=0\\n'
            """,
            extraEnvironment: [
                "CMUX_NO_PR_WATCH": "1",
                "CMUX_GH_MARKER": markerURL.path,
                "CMUX_SOCKET_PATH": socketPath.path,
                "PATH": "\(fakeBinURL.path):/usr/bin:/bin",
            ]
        )

        XCTAssertTrue(result.stdout.contains("MARKER=0"), result.stdout)
    }

    func testBashPromptResetsTerminalKeyboardProtocols() throws {
        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _cmux_prompt_command
            """,
            extraEnvironment: [
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_BUNDLED_CLI_PATH": "/usr/bin/true",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TEST_FORCE_KITTY_RESET": "1",
            ]
        )

        XCTAssertEqual(result.stdout, "\u{1B}[>m\u{1B}[<8u")
    }

    private func runInteractiveBash(
        cmuxLoadShellIntegration: Bool,
        command: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> (stdout: String, stderr: String) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationPath = repoRoot.appendingPathComponent("Resources/shell-integration/cmux-bash-integration.bash")
        let rcfilePath = root.appendingPathComponent(".bashrc")
        let rcfileContents: String = {
            guard cmuxLoadShellIntegration else { return ":\n" }
            return """
            . "\(integrationPath.path)"
            """
        }()
        try rcfileContents.write(to: rcfilePath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "--noprofile",
            "--rcfile", rcfilePath.path,
            "-i",
            "-c", command
        ]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/bash",
            "USER": NSUserName(),
        ]
        if cmuxLoadShellIntegration {
            process.environment?["CMUX_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
            process.environment?["CMUX_TAB_ID"] = "tab-test"
            process.environment?["CMUX_PANEL_ID"] = "panel-test"
        }
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Timed out waiting for bash to exit")
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, error)
        return (
            stdout: output.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func writeExecutableScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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
}
