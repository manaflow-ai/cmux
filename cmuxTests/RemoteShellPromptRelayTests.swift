import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct RemoteShellPromptRelayTests {
    @Test("remote zsh prompt reports Git metadata through the relay")
    func remoteZshPromptReportsGitMetadataThroughRelay() throws {
        let output = try runPrompt(
            shell: "/bin/zsh",
            integrationName: "cmux-zsh-integration.zsh",
            shellArguments: ["-f", "-c"],
            promptFunction: "_cmux_precmd",
            mode: "git",
            surfaceID: "22222222-2222-2222-2222-222222222222"
        )

        #expect(output.contains(
            #"rpc surface.report_git_branch {"workspace_id":"11111111-1111-1111-1111-111111111111","branch":"feature/mosh-prompt","surface_id":"22222222-2222-2222-2222-222222222222"}"#
        ), output)
    }

    @Test("remote bash prompt reports Git metadata through the relay")
    func remoteBashPromptReportsGitMetadataThroughRelay() throws {
        let output = try runPrompt(
            shell: "/bin/bash",
            integrationName: "cmux-bash-integration.bash",
            shellArguments: ["--noprofile", "--norc", "-c"],
            promptFunction: "_cmux_prompt_command",
            mode: "git",
            surfaceID: "22222222-2222-2222-2222-222222222222"
        )

        #expect(output.contains(
            #"rpc surface.report_git_branch {"workspace_id":"11111111-1111-1111-1111-111111111111","branch":"feature/mosh-prompt","surface_id":"22222222-2222-2222-2222-222222222222"}"#
        ), output)
    }

    @Test("remote tmux zsh prompt reports shell state through the workspace relay")
    func remoteTmuxZshPromptReportsShellStateThroughWorkspaceRelay() throws {
        let output = try runPrompt(
            shell: "/bin/zsh",
            integrationName: "cmux-zsh-integration.zsh",
            shellArguments: ["-f", "-c"],
            promptFunction: "_cmux_precmd",
            mode: "shell-state",
            surfaceID: nil
        )

        #expect(output.contains(
            #"rpc surface.report_shell_state {"workspace_id":"11111111-1111-1111-1111-111111111111","state":"prompt"}"#
        ), output)
    }

    @Test("remote tmux bash prompt reports shell state through the workspace relay")
    func remoteTmuxBashPromptReportsShellStateThroughWorkspaceRelay() throws {
        let output = try runPrompt(
            shell: "/bin/bash",
            integrationName: "cmux-bash-integration.bash",
            shellArguments: ["--noprofile", "--norc", "-c"],
            promptFunction: "_cmux_prompt_command",
            mode: "shell-state",
            surfaceID: nil
        )

        #expect(output.contains(
            #"rpc surface.report_shell_state {"workspace_id":"11111111-1111-1111-1111-111111111111","state":"prompt"}"#
        ), output)
    }

    private func runPrompt(
        shell: String,
        integrationName: String,
        shellArguments: [String],
        promptFunction: String,
        mode: String,
        surfaceID: String?
    ) throws -> String {
        let integration = try #require(
            RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: integrationName)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-relay-prompt-\(UUID().uuidString)", isDirectory: true)
        let repository = directory.appendingPathComponent("repository", isDirectory: true)
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        let integrationFile = directory.appendingPathComponent(integrationName)
        let cmuxFile = binDirectory.appendingPathComponent("cmux")
        let logFile = directory.appendingPathComponent("relay.log")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        guard Darwin.mkfifo(logFile.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        defer { try? FileManager.default.removeItem(at: directory) }

        try integration.write(to: integrationFile, atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/mosh-prompt\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$CMUX_TEST_LOG\"\n".write(
            to: cmuxFile,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmuxFile.path)

        let modeSetup = mode == "git"
            ? "_CMUX_SHELL_ACTIVITY_LAST=prompt"
            : "CMUX_NO_GIT_WATCH=1; export CMUX_NO_GIT_WATCH"
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shellArguments + [
            """
            source '\(integrationFile.path)'
            _CMUX_TTY_REPORTED=1
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_PORTS_LAST_RUN="$(_cmux_now)"
            \(modeSetup)
            exec 9<> "$CMUX_TEST_LOG"
            \(promptFunction)
            cmux_relay_line=""
            IFS= read -r -t 2 cmux_relay_line <&9 || true
            printf '%s\n' "$cmux_relay_line"
            exec 9>&-
            """,
        ]
        process.currentDirectoryURL = repository
        var environment = [
            "CMUX_BUNDLED_CLI_PATH": cmuxFile.path,
            "CMUX_SOCKET_PATH": "127.0.0.1:64011",
            "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
            "CMUX_TEST_LOG": logFile.path,
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
        return output
    }
}
