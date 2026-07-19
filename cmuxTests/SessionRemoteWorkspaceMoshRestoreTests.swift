import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Mosh remote workspace session restore")
struct SessionRemoteWorkspaceMoshRestoreTests {
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

    @Test("Mosh snapshots do not claim SSH persistent-PTY restore")
    func moshDoesNotRestorePersistentSSHPTY() throws {
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
    }
}
