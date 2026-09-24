import CmuxCore
import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SSHStartupManualReconnectTests {
    private final class BundleToken {}

    struct TerminalExitPromptFixture {
        let startupCommand: String
        let environment: [String: String]
        let temporaryDirectory: URL
    }

    struct TerminalExitPromptProcess {
        let process: Process
        let standardInput: Pipe
        let transcriptURL: URL
        let transcriptHandle: FileHandle
        let temporaryDirectory: URL
        let terminalPathURL: URL
    }

    /// These tests cover the legacy Workspace reconnect path. The relay port
    /// keeps this configuration there (`routesThroughSSHTui`, #14216).
    static func makeRemoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
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
    }

    static func persistentAttachSupervisorCommand(replacingSystemSSHWith fakeSSH: URL) -> String {
        // Direct process signals belong to the attach supervisor that the app
        // builds for restore and reattach.
        SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "fixture.example.test",
                port: 2222,
                identityFile: nil,
                sshOptions: ["ControlMaster=no"],
                token: UUID().uuidString.lowercased()
            )
        ).replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path)
    }

    static func generatedVMSSHInitialStartupCommand(
        replacingSystemSSHWith fakeSSH: URL
    ) throws -> String {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        let socketPath = makeSocketPath("vm-ssh-startup")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-test-startup"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:vm-startup"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return malformedRequestResponse(raw: line)
            }

            switch method {
            case "vm.ssh_info":
                let params = payload["params"] as? [String: Any] ?? [:]
                guard params["id"] as? String == vmID else {
                    return v2Response(id: id, ok: false, error: ["code": "invalid_params", "message": "unexpected attach params"])
                }
                return v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "transport": "ssh",
                        "host": "gateway.freestyle.sh",
                        "port": 2222,
                        "username": "cmux",
                        "credential": [
                            "kind": "password",
                            "value": "lease-token",
                        ],
                    ]
                )
            case "workspace.create":
                return v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.rename":
                return v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.remote.configure":
                return v2Response(
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
            case "workspace.select":
                return v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            default:
                return v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh", vmID],
            environment: environment,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))

        let requests = state.snapshot().compactMap(jsonObject)
        let createRequest = try #require(
            requests.first { ($0["method"] as? String) == "workspace.create" }
        )
        let createParams = try #require(createRequest["params"] as? [String: Any])
        let startupCommand = try #require(createParams["initial_command"] as? String)
        return try rewritingSystemSSH(in: startupCommand, with: fakeSSH)
    }

    private static func rewritingSystemSSH(
        in startupCommand: String,
        with fakeSSH: URL
    ) throws -> String {
        let systemSSHPath = "/usr/bin/ssh"
        let commandURL = URL(
            fileURLWithPath: startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: commandURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            let script = try String(contentsOf: commandURL, encoding: .utf8)
            try #require(script.contains(systemSSHPath))
            try script
                .replacingOccurrences(of: systemSSHPath, with: fakeSSH.path)
                .write(to: commandURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: commandURL.path
            )
            return startupCommand
        }

        if startupCommand.contains(systemSSHPath) {
            return startupCommand.replacingOccurrences(of: systemSSHPath, with: fakeSSH.path)
        }

        return try #require(SSHStartupCommandTestSupport.replacingPinnedSSH(
            in: startupCommand, with: fakeSSH.path
        ))
    }

    private static func makeTerminalExitPromptFixture() throws -> TerminalExitPromptFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-exit-prompt-fixture-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            try writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
            try writeShellFile(at: fakeSSH, lines: [
                "#!/bin/sh",
                "printf '%s\\n' 'Permission denied (publickey).' >&2",
                "exit 255",
            ])
            try writeShellFile(at: fakeSleep, lines: ["#!/bin/sh", "exit 0"])
            for executable in [fakeCLI, fakeSSH, fakeSleep] {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }

            let startupCommand = try generatedVMSSHInitialStartupCommand(
                replacingSystemSSHWith: fakeSSH
            )
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
            environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
            environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
            environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
            environment["CMUX_SSH_RECONNECT_LIMIT"] = "0"
            environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
            environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "2"
            return TerminalExitPromptFixture(
                startupCommand: startupCommand,
                environment: environment,
                temporaryDirectory: root
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    static func makeTerminalExitPromptProcess(
        _ suppliedFixture: TerminalExitPromptFixture? = nil
    ) throws -> TerminalExitPromptProcess {
        let fixture = try suppliedFixture ?? makeTerminalExitPromptFixture()
        let transcriptURL = fixture.temporaryDirectory.appendingPathComponent("transcript.txt")
        try Data().write(to: transcriptURL)
        let transcriptHandle = try FileHandle(forWritingTo: transcriptURL)
        let terminalPathURL = fixture.temporaryDirectory.appendingPathComponent("terminal-path.txt")
        let process = Process()
        let standardInput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "-F", "/dev/null", "/bin/sh", "-c",
            "/usr/bin/tty > \"$CMUX_TEST_PROMPT_TTY_PATH\"\n" + fixture.startupCommand,
        ]
        var environment = fixture.environment
        environment["CMUX_TEST_PROMPT_TTY_PATH"] = terminalPathURL.path
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = transcriptHandle
        process.standardError = FileHandle.nullDevice
        do {
            try SSHStartupCommandTestSupport.startProcess(process)
        } catch {
            try? transcriptHandle.close()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
            throw error
        }
        return TerminalExitPromptProcess(
            process: process,
            standardInput: standardInput,
            transcriptURL: transcriptURL,
            transcriptHandle: transcriptHandle,
            temporaryDirectory: fixture.temporaryDirectory,
            terminalPathURL: terminalPathURL
        )
    }
}
