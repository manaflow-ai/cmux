import CmuxCore
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Mosh remote workspace session restore")
struct SessionRemoteWorkspaceMoshRestoreTests {
    @Test("starts the SSH management lane before handing the terminal to Mosh")
    func startsManagementLaneBeforeMosh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mosh-management-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sshURL = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        exit 0
        """.write(to: sshURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sshURL.path)

        let moshURL = directory.appendingPathComponent("mosh")
        try """
        #!/bin/sh
        if [ "${1:-}" = "--help" ]; then
          printf '%s\n' '  --experimental-remote-ip=(local|remote|proxy)'
          exit 0
        fi
        [ -f "$READY_FILE" ] || exit 71
        printf '%s\n' "$@" > "$MOSH_ARGS_FILE"
        """.write(to: moshURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: moshURL.path)

        let readyURL = directory.appendingPathComponent("management.ready")
        let argumentsURL = directory.appendingPathComponent("mosh.args")
        let command = MoshTerminalCommandBuilder(
            capabilityProbeSSHArguments: [sshURL.path],
            sessionSSHArguments: [sshURL.path],
            destination: "user@example.com",
            remoteCommandArguments: ["printf", "remote command"],
            managementReadyShellScript: "printf ready > \"$READY_FILE\"",
            sshFallbackCommand: "exit 90",
            localMoshMissingMessage: "local Mosh missing",
            localMoshUnsupportedMessage: "local Mosh unsupported",
            remoteMoshMissingMessage: "remote Mosh missing",
            remoteMoshProbeFailedMessage: "remote Mosh probe failed"
        ).command()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
            "HOME": directory.path,
            "MOSH_ARGS_FILE": argumentsURL.path,
            "PATH": directory.path,
            "READY_FILE": readyURL.path,
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: readyURL.path))
        let moshArguments = try String(contentsOf: argumentsURL, encoding: .utf8)
        #expect(!moshArguments.contains("READY_FILE"), "\(moshArguments)")
    }

    @Test("restores the Mosh terminal preference with SSH fallback")
    func restoresMoshTerminalCommand() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .mosh,
            destination: "dev@example.com",
            port: 2222,
            identityFile: "/tmp/id with space",
            sshOptions: ["ProxyJump=bastion"]
        )

        let configuration = try #require(snapshot.workspaceConfiguration(preserveSSHOptions: true))
        let command = try #require(configuration.terminalStartupCommand)

        #expect(configuration.terminalTransport == .mosh)
        #expect(command.contains("--experimental-remote-ip=remote"), "\(command)")
        #expect(command.contains("dev@example.com"), "\(command)")
        #expect(command.contains("2222"), "\(command)")
        #expect(command.contains("ProxyJump=bastion"), "\(command)")
        #expect(command.contains("id with space"), "\(command)")
        #expect(command.contains("exec /bin/sh -c"), "\(command)")
    }

    @Test("restores a named Mosh tmux terminal profile")
    func restoresNamedMoshTmuxProfile() throws {
        let terminalProfile = try #require(WorkspaceRemoteTerminalProfile(
            kind: .tmux,
            tmuxSessionName: "agent-main"
        ))
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .mosh,
            terminalProfile: terminalProfile,
            destination: "dev@example.com",
            sshOptions: []
        )

        let configuration = try #require(snapshot.workspaceConfiguration())
        let command = try #require(configuration.terminalStartupCommand)

        #expect(configuration.terminalTransport == .mosh)
        #expect(configuration.terminalProfile == terminalProfile)
        #expect(command.contains("new-session"), "\(command)")
        #expect(command.contains("agent-main"), "\(command)")
        #expect(command.contains("exec /bin/sh -c"), "\(command)")
    }

    @Test("legacy snapshots continue to restore an SSH terminal")
    func legacySnapshotRestoresSSH() throws {
        let json = """
        {
          "transport": "ssh",
          "destination": "dev@example.com",
          "sshOptions": []
        }
        """
        let snapshot = try JSONDecoder().decode(
            SessionRemoteWorkspaceSnapshot.self,
            from: Data(json.utf8)
        )
        let configuration = try #require(snapshot.workspaceConfiguration())
        let command = try #require(configuration.terminalStartupCommand)

        #expect(configuration.terminalTransport == .ssh)
        #expect(configuration.terminalProfile == .shell)
        #expect(!command.contains("mosh"), "\(command)")
    }

    @Test("unsupported daemon bootstrap snapshots restore through SSH")
    func unsupportedDaemonBootstrapSnapshotRestoresSSH() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .mosh,
            destination: "dev@example.com",
            sshOptions: [],
            skipDaemonBootstrap: true
        )

        let configuration = try #require(snapshot.workspaceConfiguration())
        let command = try #require(configuration.terminalStartupCommand)

        #expect(configuration.terminalTransport == .ssh)
        #expect(!command.contains("mosh"), "\(command)")
    }

    @Test("Mosh restore keeps its relay namespace without claiming SSH persistent PTY")
    func moshRestoresRelayWithoutPersistentSSHPTY() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .mosh,
            destination: "dev@example.com",
            sshOptions: [],
            preserveAfterTerminalExit: true,
            relayPort: 52000,
            persistentDaemonSlot: "slot"
        )

        let configuration = try #require(snapshot.workspaceConfiguration(localSocketPath: "/tmp/cmux.sock"))

        #expect(configuration.terminalTransport == .mosh)
        #expect(!configuration.preserveAfterTerminalExit)
        #expect(configuration.persistentDaemonSlot == nil)
        #expect(configuration.relayPort == 52_000)
        #expect(configuration.relayID?.isEmpty == false)
        #expect(configuration.relayToken?.isEmpty == false)
        #expect(configuration.localSocketPath == "/tmp/cmux.sock")
        #expect(configuration.terminalStartupCommand?.contains("52000.bootstrap.sh") == true)
        #expect(configuration.terminalStartupCommand?.contains("cmux_remote_bootstrap_b64") == true)
    }
}
