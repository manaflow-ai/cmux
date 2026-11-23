import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The palette switcher shades a remote workspace's rows with the color its sidebar row shows for
/// the same server, and leaves local workspaces alone.
@MainActor
@Suite struct RemoteHostOriginColorTests {
    private func remoteWorkspace(destination: String) -> Workspace {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: destination,
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: nil,
                preserveAfterTerminalExit: false
            ),
            autoConnect: false
        )
        return workspace
    }

    @Test func aRemoteWorkspaceTakesItsHostsColorWhileTheFlagIsOn() throws {
        let registry = RemoteHostColorRegistry()
        let workspace = remoteWorkspace(destination: "dev@example.com")
        let hostColor = try #require(registry.colorHex(for: "dev@example.com"))

        #expect(RemoteHostOriginColor(enabled: true, registry: registry)
            .colorHex(for: workspace, mirrorDestinations: nil) == hostColor)
        #expect(RemoteHostOriginColor(enabled: false, registry: registry)
            .colorHex(for: workspace, mirrorDestinations: nil) == nil)
    }

    @Test func aLocalWorkspaceHasNoHostColor() {
        let registry = RemoteHostColorRegistry()
        #expect(RemoteHostOriginColor(enabled: true, registry: registry)
            .colorHex(for: Workspace(), mirrorDestinations: nil) == nil)
    }

    @Test func aManualColorWinsOnlyOnARemoteWorkspace() {
        let originColor = RemoteHostOriginColor(enabled: true, registry: RemoteHostColorRegistry())
        #expect(originColor.switcherTintHex(customColor: nil, hostColorHex: "#B1A2FA") == "#B1A2FA")
        #expect(originColor.switcherTintHex(customColor: "#C0392B", hostColorHex: "#B1A2FA") == "#C0392B")
        #expect(originColor.switcherTintHex(customColor: "#C0392B", hostColorHex: nil) == nil,
                "a local workspace's manual color is not a server color, so the switcher leaves it unshaded")
    }
}
