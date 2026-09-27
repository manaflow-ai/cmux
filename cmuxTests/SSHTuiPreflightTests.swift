import CmuxCloud
import CmuxCore
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("SSH preflight")
struct SSHTuiPreflightTests {
    @Test("Runs a prompt-free ssh true over the carrier's route")
    func runsBatchSSHOverTheRoute() async throws {
        let commands = ScriptedPreflightCommands(exitStatus: 0)
        let connection = SSHTuiConnection(configuration: configuration(options: ["ControlPath=/tmp/cm", "ConnectTimeout=5"]))
        try await SSHTuiPreflight(connection: connection, commands: commands, timeout: 7).run()
        let call = try #require(await commands.calls.first)
        #expect(call.executable == "/usr/bin/ssh")
        #expect(call.timeout == 7)
        #expect(call.arguments == ["-T", "-o", "BatchMode=yes", "-o", "RemoteCommand=none", "-o", "RequestTTY=no",
                                   "-p", "2222", "-i", "/tmp/key", "-o", "ControlPath=/tmp/cm", "-o", "ConnectTimeout=5",
                                   "-o", "ConnectTimeout=15", "alice@example.invalid", "true"])
    }

    @Test("Passes the configured agent socket like the carrier")
    func passesTheAgentSocket() async throws {
        let commands = ScriptedPreflightCommands(exitStatus: 0)
        let connection = SSHTuiConnection(configuration: configuration(agent: "/tmp/agent.sock"))
        try await SSHTuiPreflight(connection: connection, commands: commands).run()
        let call = try #require(await commands.calls.first)
        #expect(call.executable == "/usr/bin/env")
        #expect(call.arguments == ["SSH_AUTH_SOCK=/tmp/agent.sock"] + connection.preflightArguments)
    }

    @Test("Reports OpenSSH's own failure with its diagnostic")
    func reportsOpenSSHFailure() async {
        let stderr = "Warning: Permanently added 'host'.\n\nalice@example.invalid: Permission denied (publickey,password).\n"
        let commands = ScriptedPreflightCommands(exitStatus: 255, stderr: stderr)
        await #expect(throws: SSHTuiPreflightError.sshFailed(stderr)) {
            try await SSHTuiPreflight(connection: SSHTuiConnection(configuration: configuration()), commands: commands).run()
        }
        #expect(SSHTuiPreflightError.sshFailed(stderr).errorDescription
            == "Warning: Permanently added 'host'.\nalice@example.invalid: Permission denied (publickey,password).")
    }

    @Test("Treats the remote command's status as a working route")
    func remoteStatusIsSuccess() async throws {
        let commands = ScriptedPreflightCommands(exitStatus: 1)
        try await SSHTuiPreflight(connection: SSHTuiConnection(configuration: configuration()), commands: commands).run()
    }

    @Test("Reports a slow route as timed out")
    func reportsTimeout() async {
        let commands = ScriptedPreflightCommands(exitStatus: nil, timedOut: true)
        await #expect(throws: SSHTuiPreflightError.timedOut) {
            try await SSHTuiPreflight(connection: SSHTuiConnection(configuration: configuration()), commands: commands).run()
        }
    }

    @Test("Only a route that stalls before authentication asks for an interactive run")
    func classifiesStalls() {
        #expect(SSHTuiPreflightError.timedOut.stalledBeforeAuthentication)
        #expect(SSHTuiPreflightError.sshFailed("Connection timed out during banner exchange\nConnection to UNKNOWN port 65535 timed out\n")
            .stalledBeforeAuthentication)
        let chatter = (1...12).map { "proxy: waiting \($0)" }.joined(separator: "\n")
        #expect(SSHTuiPreflightError.sshFailed("Connection timed out during banner exchange\n" + chatter)
            .stalledBeforeAuthentication, "ProxyCommand output after the marker must not hide it")
        #expect(!SSHTuiPreflightError.sshFailed("ssh: connect to host example.invalid port 22: Operation timed out\n")
            .stalledBeforeAuthentication)
        #expect(!SSHTuiPreflightError.launchFailed("missing").stalledBeforeAuthentication)
    }

    @Test("Only a failed prompt-free login makes an open ask for an interactive run")
    @MainActor
    func onlyThePreflightAsksForALogin() {
        #expect(TerminalController.sshTuiNeedsInteractiveLogin(
            SSHTuiPreflightError.sshFailed("alice@example.invalid: Permission denied (publickey,password).\n")))
        #expect(TerminalController.sshTuiNeedsInteractiveLogin(SSHTuiPreflightError.timedOut))
        #expect(!TerminalController.sshTuiNeedsInteractiveLogin(
            SSHTuiPreflightError.sshFailed("ssh: connect to host example.invalid port 22: Connection refused\n")))
        // The carrier starts only after the login passed, so a remote refusal
        // it quotes is not something a password clears.
        #expect(!TerminalController.sshTuiNeedsInteractiveLogin(
            CloudMachineLink.LinkError.exited(status: 1, output: "mkdir: /home/alice/.cmux: Permission denied")))
    }

    private func configuration(options: [String] = [], agent: String? = nil) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "alice@example.invalid", port: 2222, identityFile: "/tmp/key", sshOptions: options,
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil, agentSocketPath: agent
        )
    }
}

private actor ScriptedPreflightCommands: CommandRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    init(exitStatus: Int32?, stderr: String = "", timedOut: Bool = false) {
        result = CommandResult(stdout: "", stderr: stderr, exitStatus: exitStatus, timedOut: timedOut, executionError: nil)
    }

    private let result: CommandResult
    private(set) var calls: [Call] = []

    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
        return result
    }
}
