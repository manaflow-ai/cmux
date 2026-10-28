import CmuxCore
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Eternal Terminal remote workspace session restore")
struct SessionRemoteWorkspaceEternalTerminalRestoreTests {
    @Test("persists the ET transport and options in the session snapshot")
    func snapshotPersistsEternalTerminalOptions() throws {
        let options = try #require(EternalTerminalOptions(
            serverPort: 2400,
            terminalPath: "/opt/et/bin/etterminal",
            tunnels: ["8080:80"]
        ))
        var configuration = WorkspaceRemoteConfiguration(
            terminalTransport: .et,
            destination: "dev@example.com",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 52_000,
            relayID: "relay",
            relayToken: "token",
            localSocketPath: "/tmp/cmux.sock",
            terminalStartupCommand: nil
        )
        configuration.eternalTerminalOptions = options

        let snapshot = try #require(configuration.sessionSnapshot())
        let decoded = try JSONDecoder().decode(
            SessionRemoteWorkspaceSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded.terminalTransport == .et)
        #expect(decoded.eternalTerminalOptions == options)
        #expect(decoded.relayPort == 52_000)
        #expect(decoded.sshSessionOwner == nil)
    }

    @Test("restores the ET terminal with its options and an SSH fallback")
    func restoresEternalTerminalCommand() throws {
        var snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .et,
            destination: "dev@example.com",
            port: 2222,
            identityFile: "/tmp/id with space",
            sshOptions: ["ProxyJump=bastion"]
        )
        snapshot.eternalTerminalOptions = EternalTerminalOptions(serverPort: 2400, terminalPath: "/opt/et/etterminal")

        let configuration = try #require(snapshot.workspaceConfiguration(preserveSSHOptions: true))
        let command = try #require(configuration.terminalStartupCommand)

        #expect(configuration.terminalTransport == .et)
        #expect(configuration.eternalTerminalOptions == snapshot.eternalTerminalOptions)
        #expect(command.contains("cmux_et_fallback"), "\(command)")
        #expect(command.contains("'\\''--port'\\'' '\\''2400'\\''"), "\(command)")
        #expect(command.contains("/opt/et/etterminal"), "\(command)")
        #expect(command.contains("Port=2222"), "\(command)")
        #expect(command.contains("IdentityFile=/tmp/id with space"), "\(command)")
        #expect(command.contains("ProxyJump=bastion"), "\(command)")
        #expect(command.contains("dev@example.com"), "\(command)")
        #expect(!command.contains("mosh"), "\(command)")
    }

    @Test("restores an ET snapshot without saved options through ET defaults")
    func restoresWithDefaultOptions() throws {
        let json = """
        {
          "transport": "ssh",
          "terminalTransport": "et",
          "destination": "dev@example.com",
          "sshOptions": []
        }
        """
        let snapshot = try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: Data(json.utf8))
        let configuration = try #require(snapshot.workspaceConfiguration())
        let command = try #require(configuration.terminalStartupCommand)

        #expect(configuration.terminalTransport == .et)
        #expect(configuration.eternalTerminalOptions == .default)
        #expect(command.contains("'\\''--port'\\'' '\\''2022'\\''"), "\(command)")
    }

    @Test("ET restore keeps its relay namespace and registers the launch attempt")
    func restoresRelayNamespace() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .et,
            destination: "dev@example.com",
            sshOptions: [],
            preserveAfterTerminalExit: true,
            relayPort: 52_000,
            persistentDaemonSlot: "slot"
        )

        let configuration = try #require(snapshot.workspaceConfiguration(localSocketPath: "/tmp/cmux.sock"))
        let command = try #require(configuration.terminalStartupCommand)

        #expect(configuration.terminalTransport == .et)
        #expect(!configuration.preserveAfterTerminalExit)
        #expect(configuration.relayPort == 52_000)
        #expect(configuration.localSocketPath == "/tmp/cmux.sock")
        #expect(command.contains("52000.bootstrap.sh"), "\(command)")
        #expect(command.contains("rpc workspace.remote.terminal_session_launching"), "\(command)")
    }

    @Test("skip-daemon-bootstrap ET snapshots restore through SSH")
    func unsupportedDaemonBootstrapSnapshotRestoresSSH() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .et,
            destination: "dev@example.com",
            sshOptions: [],
            skipDaemonBootstrap: true
        )

        let configuration = try #require(snapshot.workspaceConfiguration())

        #expect(configuration.terminalTransport == .ssh)
        #expect(configuration.eternalTerminalOptions == nil)
        #expect(configuration.terminalStartupCommand?.contains("cmux_et") == false)
    }
}
