import Foundation
import Testing

// Shared by the shell integration fixtures in this test target.
enum GhosttyShellIntegrationTestResources {
    static func resolve(repositoryRoot: URL, bundleResourceURL: URL? = Bundle.main.resourceURL) throws -> URL {
        let candidates = [
            bundleResourceURL?.appendingPathComponent("ghostty", isDirectory: true),
            repositoryRoot.appendingPathComponent("ghostty/src", isDirectory: true),
        ].compactMap { $0 }
        for candidate in candidates {
            let integration = candidate.appendingPathComponent("shell-integration/zsh/ghostty-integration")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: integration.path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isReadableFile(atPath: integration.path) {
                return candidate
            }
        }
        throw NSError(
            domain: "GhosttyShellIntegrationTestResources",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Ghostty zsh integration is missing from the app product and source checkout: "
                    + candidates.map(\.path).joined(separator: ", ")]
        )
    }
}

@Suite
struct GhosttyShellIntegrationTestResourcesTests {
    private func makeResourceTree(_ root: URL) throws {
        let integration = root.appendingPathComponent("shell-integration/zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: integration, withIntermediateDirectories: true)
        try "# fixture integration\n".write(
            to: integration.appendingPathComponent("ghostty-integration"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test
    func productOnlyConsumerUsesBundledResourcesWithoutASubmodule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleResources = root.appendingPathComponent("cmux.app/Contents/Resources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try makeResourceTree(bundledGhostty)
        let resolved = try GhosttyShellIntegrationTestResources.resolve(
            repositoryRoot: root.appendingPathComponent("checkout"),
            bundleResourceURL: bundleResources
        )
        #expect(resolved == bundledGhostty)
    }

    @Test
    func completeBundleWinsOverADeveloperSubmodule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleResources = root.appendingPathComponent("Resources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try makeResourceTree(bundledGhostty)
        try makeResourceTree(root.appendingPathComponent("ghostty/src", isDirectory: true))
        #expect(try GhosttyShellIntegrationTestResources.resolve(
            repositoryRoot: root, bundleResourceURL: bundleResources
        ) == bundledGhostty)
    }

    @Test
    func developerCheckoutIsUsedWhenBundleIsIncomplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ghostty/src", isDirectory: true)
        try makeResourceTree(source)
        #expect(try GhosttyShellIntegrationTestResources.resolve(
            repositoryRoot: root, bundleResourceURL: root.appendingPathComponent("missing")
        ) == source)
    }

    @Test
    func missingIntegrationIsAnErrorRatherThanASkip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: NSError.self) {
            try GhosttyShellIntegrationTestResources.resolve(repositoryRoot: root, bundleResourceURL: nil)
        }
    }
}

@Suite(.serialized)
struct RemoteShellCWDRelayTests {
    @Test
    func zshChpwdReportsLocalPWDImmediately() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-local-cwd-\(UUID().uuidString)")
        let target = root.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integration = repositoryRoot
            .appendingPathComponent("Resources/shell-integration/cmux-zsh-integration.zsh")

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-f",
            "-c",
            """
            source '\(integration.path)'
            _cmux_socket_is_unix() { return 0 }
            _cmux_send_bg() { print -r -- "$@" }
            cd '\(target.path)'
            """,
        ]
        process.environment = [
            "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            "CMUX_SOCKET_PATH": "/tmp/cmux-local-cwd-test.sock",
            "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
            "HOME": root.path,
            "PATH": "/usr/bin:/bin",
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let error = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0, "\(error)\n\(output)")
        #expect(output.contains(
            "report_pwd \"\(target.path)\" "
                + "--tab=11111111-1111-1111-1111-111111111111 "
                + "--panel=22222222-2222-2222-2222-222222222222"
        ), Comment(rawValue: output))
    }

    @Test
    func zshRelayPromptReportsRemotePWD() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-relay-pwd-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let remoteDirectory = root.appendingPathComponent("remote-cwd", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            command: """
            : > "\(logPath.path)"
            cd "\(remoteDirectory.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _CMUX_PWD_LAST_PWD="/tmp/local-launch"
            _cmux_precmd
            # _cmux_precmd reports shell state and the pwd from separate
            # background calls, so wait for the pwd line itself rather than
            # for the first line of any kind.
            repeat 100; do
              [[ -s "\(logPath.path)" && "$(<"\(logPath.path)")" == *surface.report_pwd* ]] && break
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

        let expected = #"rpc surface.report_pwd {"workspace_id":"11111111-1111-1111-1111-111111111111","path":"\#(remoteDirectory.path)","surface_id":"22222222-2222-2222-2222-222222222222"}"#
        #expect(output.contains(expected), Comment(rawValue: output))
    }

    @Test
    func bashRelayPromptReportsRemotePWD() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-pwd-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let remoteDirectory = root.appendingPathComponent("remote-cwd", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
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
            command: """
            : > "\(logPath.path)"
            cd "\(remoteDirectory.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _CMUX_PWD_LAST_PWD="/tmp/local-launch"
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

        let expected = #"rpc surface.report_pwd {"workspace_id":"11111111-1111-1111-1111-111111111111","path":"\#(remoteDirectory.path)","surface_id":"22222222-2222-2222-2222-222222222222"}"#
        #expect(result.stdout.contains(expected), Comment(rawValue: result.stdout))
    }

    private func runInteractiveZsh(
        command: String,
        extraEnvironment: [String: String]
    ) throws -> String {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let userZdotdir = root.appendingPathComponent("zdotdir")
        try fileManager.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
        var userZshEnvFileContents = "\n"
        if let path = extraEnvironment["PATH"] {
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            userZshEnvFileContents = "export PATH=\"\(escaped)\"\n"
        }
        try userZshEnvFileContents.write(
            to: userZdotdir.appendingPathComponent(".zshenv"),
            atomically: true,
            encoding: .utf8
        )

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cmuxZdotdir = repoRoot.appendingPathComponent("Resources/shell-integration")
        let ghosttyResources = try GhosttyShellIntegrationTestResources.resolve(repositoryRoot: repoRoot)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i", "-c", command]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "ZDOTDIR": cmuxZdotdir.path,
            "CMUX_ZSH_ZDOTDIR": userZdotdir.path,
            "CMUX_SHELL_INTEGRATION": "1",
            "CMUX_SHELL_INTEGRATION_DIR": cmuxZdotdir.path,
            "GHOSTTY_RESOURCES_DIR": ghosttyResources.path,
        ]
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let output = try runProcess(process)
        #expect(output.status == 0, Comment(rawValue: output.stderr))
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runInteractiveBash(
        command: String,
        extraEnvironment: [String: String]
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
        try ". \"\(integrationPath.path)\"\n".write(to: rcfilePath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--rcfile", rcfilePath.path, "-i", "-c", command]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/bash",
            "USER": NSUserName(),
        ]
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let output = try runProcess(process)
        #expect(output.status == 0, Comment(rawValue: output.stderr))
        return (
            stdout: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func runProcess(_ process: Process) throws -> (status: Int32, stdout: String, stderr: String) {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date.now.addingTimeInterval(5)
        while process.isRunning && Date.now < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw NSError(
                domain: "RemoteShellCWDRelayTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for shell to exit"]
            )
        }

        return (
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func writeExecutableScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
