import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceGitMetadataWatcherContextMenuTests: XCTestCase {
    func testContextMenuModeUsesEffectiveGlobalWatcherState() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.gitMetadataWatcherDisabled = false

        XCTAssertEqual(
            ContentView.workspaceGitMetadataWatcherContextMenuMode(
                targetWorkspaces: [workspace],
                globalDisabled: true
            ),
            .enable
        )
    }

    func testContextMenuModeHidesToggleWhenAnyTargetWorkspaceIsRemote() {
        let manager = TabManager()
        guard let localWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected local workspace")
            return
        }

        let remoteWorkspace = manager.addWorkspace(select: false)
        remoteWorkspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64017,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )

        XCTAssertEqual(
            ContentView.workspaceGitMetadataWatcherContextMenuMode(
                targetWorkspaces: [localWorkspace, remoteWorkspace],
                globalDisabled: false
            ),
            .hidden
        )
    }

    func testSetWorkspaceGitMetadataWatcherDisabledSkipsRemoteWorkspace() {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: false)
        remoteWorkspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64017,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )

        XCTAssertTrue(remoteWorkspace.isRemoteWorkspace)

        manager.setWorkspaceGitMetadataWatcherDisabled(
            workspaceIds: [remoteWorkspace.id],
            disabled: true
        )

        XCTAssertFalse(remoteWorkspace.gitMetadataWatcherDisabled)
    }
}
