import Foundation
import Testing

private let shellIntegrationFishExecutablePath = [
    "/opt/homebrew/bin/fish",
    "/usr/local/bin/fish",
    "/usr/bin/fish",
    "/bin/fish",
].first { FileManager.default.isExecutableFile(atPath: $0) }

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct ShellIntegrationSendTransportTests {
    @Test("remote zsh reports Git metadata through the relay")
    func remoteZshReportsGitMetadataThroughRelay() throws {
        try assertRemoteShellReportsGitMetadataThroughRelay(
            shell: "/bin/zsh",
            integrationName: "cmux-zsh-integration.zsh",
            shellArguments: ["-f", "-c"]
        )
    }

    @Test("remote bash reports Git metadata through the relay")
    func remoteBashReportsGitMetadataThroughRelay() throws {
        try assertRemoteShellReportsGitMetadataThroughRelay(
            shell: "/bin/bash",
            integrationName: "cmux-bash-integration.bash",
            shellArguments: ["--noprofile", "--norc", "-c"]
        )
    }

    @Test("remote tmux zsh reports Git metadata through the workspace relay")
    func remoteTmuxZshReportsWorkspaceScopedGitMetadataThroughRelay() throws {
        try assertRemoteShellReportsGitMetadataThroughRelay(
            shell: "/bin/zsh",
            integrationName: "cmux-zsh-integration.zsh",
            shellArguments: ["-f", "-c"],
            surfaceID: nil
        )
    }

    @Test("remote tmux bash reports Git metadata through the workspace relay")
    func remoteTmuxBashReportsWorkspaceScopedGitMetadataThroughRelay() throws {
        try assertRemoteShellReportsGitMetadataThroughRelay(
            shell: "/bin/bash",
            integrationName: "cmux-bash-integration.bash",
            shellArguments: ["--noprofile", "--norc", "-c"],
            surfaceID: nil
        )
    }

    @Test(
        "fish publishes remote workspace relay metadata before tmux attach",
        .enabled(if: shellIntegrationFishExecutablePath != nil)
    )
    func fishPublishesRemoteWorkspaceRelayMetadataBeforeTmuxAttach() throws {
        let fish = try #require(shellIntegrationFishExecutablePath)
        let integration = try #require(
            RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                named: "fish/config.fish"
            )
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fish-tmux-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let integrationFile = directory.appendingPathComponent("config.fish")
        let logFile = directory.appendingPathComponent("tmux.log")
        try integration.write(to: integrationFile, atomically: true, encoding: .utf8)

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: fish)
        process.arguments = [
            "-c",
            """
            source '\(integrationFile.path)'
            function tmux
                string join ' ' -- $argv >> "$CMUX_TEST_LOG"
            end
            _cmux_tmux_sync_cmux_environment
            cat "$CMUX_TEST_LOG"
            """,
        ]
        process.environment = [
            "CMUX_PANEL_ID": "stale-surface",
            "CMUX_SOCKET_PATH": "127.0.0.1:64011",
            "CMUX_SURFACE_ID": "stale-surface",
            "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
            "CMUX_TEST_LOG": logFile.path,
            "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
            "HOME": directory.path,
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 0, "\(error)\n\(output)")
        #expect(
            output.contains("set-environment -g CMUX_SOCKET_PATH 127.0.0.1:64011"),
            Comment(rawValue: output)
        )
        #expect(
            output.contains("set-environment -g CMUX_WORKSPACE_ID 11111111-1111-1111-1111-111111111111"),
            Comment(rawValue: output)
        )
        #expect(output.contains("set-environment -gu CMUX_SURFACE_ID"), Comment(rawValue: output))
        #expect(output.contains("set-environment -gu CMUX_PANEL_ID"), Comment(rawValue: output))
    }

    @Test("reattached tmux zsh adopts the named session workspace binding")
    func tmuxZshAdoptsSessionWorkspaceBinding() throws {
        try assertTmuxShellAdoptsSessionWorkspaceBinding(
            shell: "/bin/zsh",
            integrationName: "cmux-zsh-integration.zsh"
        )
    }

    @Test("reattached tmux bash adopts the named session workspace binding")
    func tmuxBashAdoptsSessionWorkspaceBinding() throws {
        try assertTmuxShellAdoptsSessionWorkspaceBinding(
            shell: "/bin/bash",
            integrationName: "cmux-bash-integration.bash"
        )
    }

    private func assertTmuxShellAdoptsSessionWorkspaceBinding(
        shell: String,
        integrationName: String
    ) throws {
        let script = try #require(
            RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: integrationName)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tmux-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptFile = directory.appendingPathComponent(integrationName)
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-f", "-c", Self.tmuxEnvironmentRefreshScript(scriptFile: scriptFile)]
        if shell.hasSuffix("bash") {
            process.arguments = ["--noprofile", "--norc", "-c", Self.tmuxEnvironmentRefreshScript(scriptFile: scriptFile)]
        }
        process.environment = [
            "CMUX_PANEL_ID": "stale-surface",
            "CMUX_SOCKET_PATH": "127.0.0.1:63135",
            "CMUX_SURFACE_ID": "stale-surface",
            "CMUX_TAB_ID": "stale-workspace",
            "CMUX_WORKSPACE_ID": "stale-workspace",
            "HOME": directory.path,
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
            "TMUX": "/tmp/tmux-test,1,0",
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 0, "\(error)\n\(output)")
        #expect(output.contains("workspace=current-workspace"), Comment(rawValue: output))
        #expect(output.contains("socket=127.0.0.1:55272"), Comment(rawValue: output))
        #expect(output.contains("surface=<unset>"), Comment(rawValue: output))
        #expect(output.contains("panel=<unset>"), Comment(rawValue: output))
    }

    private func assertRemoteShellReportsGitMetadataThroughRelay(
        shell: String,
        integrationName: String,
        shellArguments: [String],
        surfaceID: String? = "22222222-2222-2222-2222-222222222222"
    ) throws {
        let integration = try #require(
            RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: integrationName)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-relay-git-\(UUID().uuidString)", isDirectory: true)
        let repository = directory.appendingPathComponent("repository", isDirectory: true)
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        let integrationFile = directory.appendingPathComponent(integrationName)
        let cmuxFile = binDirectory.appendingPathComponent("cmux")
        let logFile = directory.appendingPathComponent("relay.log")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try integration.write(to: integrationFile, atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/mosh-parity\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(logFile.path)'\n".write(
            to: cmuxFile,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmuxFile.path)

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shellArguments + [
            "source '\(integrationFile.path)'; _cmux_report_git_branch_for_path \"$PWD\"; cat '\(logFile.path)'"
        ]
        process.currentDirectoryURL = repository
        var environment = [
            "CMUX_BUNDLED_CLI_PATH": cmuxFile.path,
            "CMUX_SOCKET_PATH": "127.0.0.1:64011",
            "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
            "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
            "HOME": directory.path,
            "PATH": "\(binDirectory.path):/usr/bin:/bin",
            "TERM": "xterm-256color",
        ]
        if let surfaceID {
            environment["CMUX_PANEL_ID"] = surfaceID
            environment["CMUX_SURFACE_ID"] = surfaceID
        }
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 0, "\(error)\n\(output)")
        let surfaceField = surfaceID.map { ",\"surface_id\":\"\($0)\"" } ?? ""
        #expect(output.contains(
            #"rpc surface.report_git_branch {"workspace_id":"11111111-1111-1111-1111-111111111111","branch":"feature/mosh-parity"\#(surfaceField)}"#
        ), Comment(rawValue: output))
    }

    /// End-to-end contract for `_cmux_send`: sourcing the bundled integration
    /// in a fresh zsh and sending one payload must deliver that payload to a
    /// unix-socket listener even when a PATH-first `nc` without unix-socket
    /// support (GNU netcat's shape) shadows the system client. This transport
    /// carries the whole hook channel (report_tty, ports_kick,
    /// report_shell_state, git/PR reports) and previously dropped every
    /// message on such machines.
    ///
    /// Skipped on CI app-host runners: subprocess unix-socket delivery is
    /// flaky there (the identical un-shimmed flow passes and fails across
    /// runs while `/usr/bin/nc` is executable and the send exits 0; child
    /// runtimes of ~11s point at VM scheduling, not the change). The
    /// regression class this guards, Homebrew GNU nc shadowing the system
    /// client, lives on developer machines, where this test always runs.
    /// GITHUB_ACTIONS does not survive into the elevated app-host process, so
    /// detect the CI machines by their console user: every CI runner image
    /// executes tests as `runner`, and no developer or fleet Mac does.
    @Test(.enabled(
        if: NSUserName() != "runner",
        "subprocess unix-socket delivery is flaky on CI app-host runners; run locally or on a fleet Mac"
    ))
    func sendDeliversPayloadDespiteShadowedPathNC() throws {
        let result = try Self.deliverViaIntegration(shimmed: true)
        #expect(
            result.delivered == "transport probe",
            "The pinned system client must deliver even with a broken PATH-first nc. exit=\(result.exitStatus) log:\n\(result.diagnostics.suffix(1200))"
        )
    }

    private struct DeliveryResult {
        let delivered: String?
        let diagnostics: String
        let exitStatus: Int32
    }

    private static func deliverViaIntegration(shimmed: Bool) throws -> DeliveryResult {
        let script = try #require(
            RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                named: "cmux-zsh-integration.zsh"
            ),
            "cmux-zsh-integration.zsh must ship in the app bundle"
        )
        // Deliberately short root: unix socket paths must fit
        // sockaddr_un.sun_path (104 bytes on Darwin), and the default
        // temporaryDirectory under /var/folders is long enough to overflow it.
        let dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-st-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptFile = dir.appendingPathComponent("integration.zsh")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        let socketPath = dir.appendingPathComponent("t.sock").path

        var path = "/usr/bin:/bin"
        if shimmed {
            // Reproduce the regression: a PATH-first `nc` without unix-socket
            // support that fails every invocation. The transport must deliver
            // anyway by pinning the system client.
            let shimDir = dir.appendingPathComponent("shims", isDirectory: true)
            try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
            let shim = shimDir.appendingPathComponent("nc")
            try "#!/bin/sh\nexit 1\n".write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            path = "\(shimDir.path):/usr/bin:/bin"
        }

        let listener = try UnixLineListener(path: socketPath)

        // Output goes to files, not pipes: an unread pipe can deadlock the
        // child, and the file contents become the failure diagnostics.
        let logURL = dir.appendingPathComponent("run.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.environment = [
            "CMUX_SOCKET_PATH": socketPath,
            "PATH": path,
            "HOME": dir.path,
        ]
        process.arguments = [
            "-f", "-c",
            """
            source '\(scriptFile.path)'
            print -r -- "diag: usrbin_nc_executable=$([[ -x /usr/bin/nc ]] && echo 1 || echo 0)"
            print -r -- "diag: path_nc=$(whence -p nc 2>/dev/null)"
            _cmux_send 'transport probe'
            print -r -- "diag: send_rc=$?"
            """,
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()

        return DeliveryResult(
            delivered: listener.waitForLine(timeout: 10),
            diagnostics: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<no log>",
            exitStatus: process.terminationStatus
        )
    }

    private static func tmuxEnvironmentRefreshScript(scriptFile: URL) -> String {
        """
        source '\(scriptFile.path)'
        tmux() {
          if [ "$1" = show-environment ]; then
            if [ "${2:-}" = -g ]; then
              printf '%s\\n' 'CMUX_SOCKET_PATH=127.0.0.1:63135' 'CMUX_TAB_ID=stale-workspace' 'CMUX_WORKSPACE_ID=stale-workspace'
            else
              printf '%s\\n' 'CMUX_SOCKET_PATH=127.0.0.1:55272' 'CMUX_TAB_ID=current-workspace' 'CMUX_WORKSPACE_ID=current-workspace'
            fi
          fi
        }
        _cmux_tmux_sync_cmux_environment
        printf 'workspace=%s\\nsocket=%s\\nsurface=%s\\npanel=%s\\n' \
          "${CMUX_WORKSPACE_ID:-<unset>}" "${CMUX_SOCKET_PATH:-<unset>}" \
          "${CMUX_SURFACE_ID:-<unset>}" "${CMUX_PANEL_ID:-<unset>}"
        """
    }
}

/// Minimal blocking unix-socket listener: accepts one client, reads one line,
/// replies "OK" and closes so response-waiting clients exit promptly.
private final class UnixLineListener: @unchecked Sendable {
    private let serverFD: Int32
    private let received = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var line: String?

    init(path: String) throws {
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw POSIXError(.EMFILE) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        try path.withCString { cs in
            guard strlen(cs) <= maxLen else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.baseAddress!.copyMemory(from: cs, byteCount: Int(strlen(cs)) + 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, size)
            }
        }
        guard bound == 0, listen(serverFD, 4) == 0 else {
            close(serverFD)
            throw POSIXError(.EADDRINUSE)
        }
        let fd = serverFD
        DispatchQueue.global().async { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !data.contains(0x0A) {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[0..<count])
            }
            _ = "OK\n".withCString { write(client, $0, 3) }
            close(client)
            guard let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.lock()
            self.line = text.split(separator: "\n").first.map(String.init)
            self.lock.unlock()
            self.received.signal()
        }
    }

    func waitForLine(timeout: TimeInterval) -> String? {
        _ = received.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return line
    }

    deinit { close(serverFD) }
}
