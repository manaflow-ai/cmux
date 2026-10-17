import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for `cmux ssh-tmux <destination> kill <session>`
/// (https://github.com/manaflow-ai/cmux/issues/21201): the one-shot terminates exactly
/// the named session and reports an unknown one as a distinct failure.
@Suite struct RemoteTmuxKillSessionTests {
    @Test func killTargetsTheExactSessionName() async throws {
        let env = try KillSessionFakeSSH(exitCode: 0, stderr: "")
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        try await transport.killSession(named: "work")

        let remoteCommand = try #require(env.loggedArguments().last)
        #expect(remoteCommand.contains("kill-session"))
        // `=` makes tmux match the name exactly instead of by prefix.
        #expect(remoteCommand.contains("'=work'"))
        #expect(!remoteCommand.contains("kill-server"))
    }

    @Test(arguments: [
        "can't find session: work",
        "session not found: work",
        "no server running on /tmp/tmux-501/default",
    ])
    func unknownSessionIsReportedAsNotFound(stderr: String) async throws {
        let env = try KillSessionFakeSSH(exitCode: 1, stderr: stderr)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        await #expect(throws: RemoteTmuxError.sessionNotFound(session: "work", destination: "user@host")) {
            try await transport.killSession(named: "work")
        }
        #expect(
            RemoteTmuxError.sessionNotFound(session: "work", destination: "user@host").message
                == "no tmux session named 'work' on user@host"
        )
    }

    @Test func sshFailureIsNotMistakenForAnUnknownSession() async throws {
        let env = try KillSessionFakeSSH(exitCode: 255, stderr: "ssh: connect to host host port 22: Connection refused")
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        do {
            try await transport.killSession(named: "work")
            Issue.record("Expected killSession to fail when ssh fails")
        } catch let error as RemoteTmuxError {
            guard case .commandFailed(let exitCode, _) = error else {
                Issue.record("Expected commandFailed, got \(error)")
                return
            }
            #expect(exitCode == 255)
        }
    }

    @Test func socketMethodIsAdvertisedAndRefusesAMissingSessionBeforeNetwork() throws {
        let capabilities = try Self.socketResponse(method: "system.capabilities", params: "{}")
        let result = try #require(capabilities["result"] as? [String: Any])
        let methods = try #require(result["methods"] as? [String])
        #expect(methods.contains("remote.tmux.kill_session"))

        for params in [#"{}"#, #"{"host":"user@host"}"#, #"{"host":"user@host","session":"  "}"#] {
            let response = try Self.socketResponse(method: "remote.tmux.kill_session", params: params)
            #expect(response["ok"] as? Bool == false)
            let error = try #require(response["error"] as? [String: Any])
            let code = try #require(error["code"] as? String)
            #expect(code == "disabled" || code == "invalid_params" || code == "remote_connections_disabled")
        }
    }

    private static func socketResponse(method: String, params: String) throws -> [String: Any] {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":\#(params)}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }
}

/// A stand-in `ssh` that records its argv (one argument per line) and fails or
/// succeeds as configured.
private struct KillSessionFakeSSH {
    let root: URL
    let executablePath: String
    private let logPath: String

    init(exitCode: Int32, stderr: String) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-kill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        logPath = root.appendingPathComponent("argv.log").path

        let script = """
        #!/bin/sh
        for arg in "$@"; do printf '%s\\n' "$arg" | tr '\\n' ' ' >> \(Self.shellSingleQuoted(logPath)); printf '\\n' >> \(Self.shellSingleQuoted(logPath)); done
        if [ -n \(Self.shellSingleQuoted(stderr)) ]; then printf '%s\\n' \(Self.shellSingleQuoted(stderr)) >&2; fi
        exit \(exitCode)
        """
        let scriptURL = root.appendingPathComponent("ssh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        executablePath = scriptURL.path
    }

    func loggedArguments() throws -> [String] {
        try String(contentsOfFile: logPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
