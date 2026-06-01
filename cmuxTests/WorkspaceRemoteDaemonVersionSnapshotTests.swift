import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Remote workspace daemon version snapshots")
struct WorkspaceRemoteDaemonVersionSnapshotTests {
    @Test("Persistent SSH snapshots store the current remote daemon version")
    func persistentSSHSnapshotsStoreCurrentRemoteDaemonVersion() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        let persistentDaemonSlot = "ssh-version-snapshot"
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64024,
            relayID: "relay-version-snapshot",
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-version-snapshot.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: persistentDaemonSlot
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let persistedWorkspace = try #require(snapshot.workspaces.first)

        #expect(persistedWorkspace.remote?.persistentDaemonSlot == persistentDaemonSlot)
        #expect(persistedWorkspace.remote?.remoteDaemonVersion == Workspace.currentRemoteDaemonVersion())
    }

    @Test("Legacy persistent SSH snapshots without a daemon version fall back to fresh SSH")
    func legacyPersistentSSHSnapshotWithoutDaemonVersionFallsBackToFreshSSH() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: nil,
            relayPort: 64021,
            persistentDaemonSlot: "ssh-legacy-no-version"
        )

        let configuration = try #require(
            snapshot.workspaceConfiguration(localSocketPath: "/tmp/cmux-restore.sock")
        )

        #expect(configuration.preserveAfterTerminalExit == false)
        #expect(configuration.foregroundAuthToken == nil)
        #expect(configuration.persistentDaemonSlot == nil)
        #expect(configuration.relayPort == nil)
        #expect(configuration.localSocketPath == nil)
        #expect(configuration.terminalStartupCommand?.contains("ssh-pty-attach") != true)
        #expect(
            configuration.terminalStartupCommand == "ssh -p 2222 -o StrictHostKeyChecking=accept-new -tt dev@example.com"
        )
    }

    @Test("Mismatched daemon versions fall back to fresh SSH")
    func mismatchedDaemonVersionsFallBackToFreshSSH() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: nil,
            relayPort: 64022,
            persistentDaemonSlot: "ssh-old-nightly",
            remoteDaemonVersion: "0.64.10-nightly.123"
        )

        let configuration = try #require(
            snapshot.workspaceConfiguration(
                localSocketPath: "/tmp/cmux-restore.sock",
                currentRemoteDaemonVersion: "0.64.10-nightly.456"
            )
        )

        #expect(configuration.preserveAfterTerminalExit == false)
        #expect(configuration.foregroundAuthToken == nil)
        #expect(configuration.persistentDaemonSlot == nil)
        #expect(configuration.relayPort == nil)
        #expect(configuration.localSocketPath == nil)
        #expect(configuration.terminalStartupCommand?.contains("ssh-pty-attach") != true)
        #expect(
            configuration.terminalStartupCommand == "ssh -p 2222 -o StrictHostKeyChecking=accept-new -tt dev@example.com"
        )
    }

    @Test("Matching daemon versions restore persistent SSH PTY attach")
    func matchingDaemonVersionsRestorePersistentSSHPTYAttach() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: nil,
            relayPort: 64023,
            persistentDaemonSlot: "ssh-current-nightly",
            remoteDaemonVersion: "0.64.10-nightly.456"
        )

        let configuration = try #require(
            snapshot.workspaceConfiguration(
                localSocketPath: "/tmp/cmux-restore.sock",
                currentRemoteDaemonVersion: "0.64.10-nightly.456"
            )
        )

        #expect(configuration.preserveAfterTerminalExit == true)
        #expect(configuration.foregroundAuthToken != nil)
        #expect(configuration.persistentDaemonSlot == "ssh-current-nightly")
        #expect(configuration.relayPort == 64023)
        #expect(configuration.localSocketPath == "/tmp/cmux-restore.sock")
        let terminalStartupCommand = try #require(configuration.terminalStartupCommand)
        #expect(terminalStartupCommand.contains("ssh-pty-attach"))
        #expect(terminalStartupCommand.contains("--require-existing"))
    }
}
