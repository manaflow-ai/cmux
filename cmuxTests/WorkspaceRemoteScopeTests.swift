import Bonsplit
import CmuxCore
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceRemoteScopeTests: XCTestCase {
    private let startupCommand = "ssh dev@example.com"

    private func remoteConfiguration(
        scope: WorkspaceRemoteScope = .pane,
        destination: String = "dev@example.com"
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: destination,
            port: 2222,
            identityFile: nil,
            scope: scope,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: startupCommand
        )
    }

    private func workspaceWithLocalSibling() throws -> (workspace: Workspace, seed: UUID, local: TerminalPanel) {
        let workspace = Workspace()
        let seed = try XCTUnwrap(workspace.focusedPanelId)
        let local = try XCTUnwrap(workspace.newTerminalSplit(
            from: seed,
            orientation: .horizontal,
            focus: true
        ))
        return (workspace, seed, local)
    }

    func testPaneScopeConfigureTracksOnlySeedPanel() throws {
        let (workspace, seed, local) = try workspaceWithLocalSibling()

        workspace.configureRemoteConnection(
            remoteConfiguration(),
            autoConnect: false,
            seedPanelId: seed
        )

        XCTAssertTrue(workspace.isRemoteTerminalSurface(seed))
        XCTAssertFalse(workspace.isRemoteTerminalSurface(local.id))
    }

    func testTerminalSplitsInheritOnlyFromRemoteSourcePane() throws {
        let (workspace, seed, local) = try workspaceWithLocalSibling()
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false, seedPanelId: seed)

        let remoteSplit = try XCTUnwrap(workspace.newTerminalSplit(
            from: seed,
            orientation: .vertical,
            focus: false
        ))
        let localSplit = try XCTUnwrap(workspace.newTerminalSplit(
            from: local.id,
            orientation: .vertical,
            focus: false
        ))

        XCTAssertTrue(workspace.isRemoteTerminalSurface(remoteSplit.id))
        XCTAssertEqual(remoteSplit.surface.debugInitialCommand(), startupCommand)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(localSplit.id))
        XCTAssertNil(localSplit.surface.debugInitialCommand())
    }

    func testTerminalTabsInheritOnlyFromSelectedRemotePane() throws {
        let (workspace, seed, local) = try workspaceWithLocalSibling()
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false, seedPanelId: seed)
        let remotePane = try XCTUnwrap(workspace.paneId(forPanelId: seed))
        let localPane = try XCTUnwrap(workspace.paneId(forPanelId: local.id))

        let remoteTab = try XCTUnwrap(workspace.newTerminalSurface(inPane: remotePane, focus: false))
        let localTab = try XCTUnwrap(workspace.newTerminalSurface(inPane: localPane, focus: false))

        XCTAssertTrue(workspace.isRemoteTerminalSurface(remoteTab.id))
        XCTAssertEqual(remoteTab.surface.debugInitialCommand(), startupCommand)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(localTab.id))
        XCTAssertNil(localTab.surface.debugInitialCommand())
    }

    func testBrowserSplitsRecordOnlyRemoteScopedMembers() throws {
        let wasBrowserDisabled = !BrowserAvailabilitySettings.isEnabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }
        let (workspace, seed, local) = try workspaceWithLocalSibling()
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false, seedPanelId: seed)

        let remoteBrowser = try XCTUnwrap(workspace.newBrowserSplit(
            from: seed,
            orientation: .vertical,
            focus: false
        ))
        let localBrowser = try XCTUnwrap(workspace.newBrowserSplit(
            from: local.id,
            orientation: .vertical,
            focus: false
        ))

        XCTAssertTrue(workspace.remoteScopedBrowserPanelIds.contains(remoteBrowser.id))
        XCTAssertFalse(workspace.remoteScopedBrowserPanelIds.contains(localBrowser.id))
    }

    func testRemoteScopedBrowserSourcesPropagatePaneScopeToChildSurfaces() throws {
        let wasBrowserDisabled = !BrowserAvailabilitySettings.isEnabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }
        let (workspace, seed, local) = try workspaceWithLocalSibling()
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false, seedPanelId: seed)

        let remoteBrowser = try XCTUnwrap(workspace.newBrowserSplit(
            from: seed,
            orientation: .vertical,
            focus: false
        ))
        let localBrowser = try XCTUnwrap(workspace.newBrowserSplit(
            from: local.id,
            orientation: .vertical,
            focus: false
        ))
        let terminalFromRemoteBrowser = try XCTUnwrap(workspace.newTerminalSplit(
            from: remoteBrowser.id,
            orientation: .horizontal,
            focus: false
        ))
        let browserFromRemoteBrowser = try XCTUnwrap(workspace.newBrowserSplit(
            from: remoteBrowser.id,
            orientation: .horizontal,
            focus: false
        ))
        let terminalFromLocalBrowser = try XCTUnwrap(workspace.newTerminalSplit(
            from: localBrowser.id,
            orientation: .horizontal,
            focus: false
        ))
        let browserFromLocalBrowser = try XCTUnwrap(workspace.newBrowserSplit(
            from: localBrowser.id,
            orientation: .horizontal,
            focus: false
        ))

        XCTAssertTrue(workspace.remoteScopedBrowserPanelIds.contains(remoteBrowser.id))
        XCTAssertTrue(workspace.isRemoteTerminalSurface(terminalFromRemoteBrowser.id))
        XCTAssertEqual(terminalFromRemoteBrowser.surface.debugInitialCommand(), startupCommand)
        XCTAssertTrue(workspace.remoteScopedBrowserPanelIds.contains(browserFromRemoteBrowser.id))
        XCTAssertFalse(workspace.remoteScopedBrowserPanelIds.contains(localBrowser.id))
        XCTAssertFalse(workspace.isRemoteTerminalSurface(terminalFromLocalBrowser.id))
        XCTAssertNil(terminalFromLocalBrowser.surface.debugInitialCommand())
        XCTAssertFalse(workspace.remoteScopedBrowserPanelIds.contains(browserFromLocalBrowser.id))
    }

    func testDisconnectRemoteSurfaceDemotesOnlyAfterLastMemberWithoutScopedBrowsers() throws {
        let (workspace, seed, local) = try workspaceWithLocalSibling()
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false, seedPanelId: seed)
        XCTAssertEqual(workspace.joinPaneScopedRemoteConnection(seedPanelId: local.id), startupCommand)

        workspace.disconnectRemoteSurface(panelId: seed)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(seed))
        XCTAssertNotNil(workspace.remoteConfiguration)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(local.id))

        workspace.disconnectRemoteSurface(panelId: local.id)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(local.id))
        XCTAssertNil(workspace.remoteConfiguration)
    }

    func testJoinPaneScopedRemoteConnectionTracksSeedAndReturnsStartupCommand() throws {
        let (workspace, seed, local) = try workspaceWithLocalSibling()
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false, seedPanelId: seed)

        let command = workspace.joinPaneScopedRemoteConnection(seedPanelId: local.id)

        XCTAssertEqual(command, startupCommand)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(local.id))
    }

    func testPaneScopedRemoteRestoreRoundTripsTerminalAndBrowserMembership() throws {
        let wasBrowserDisabled = !BrowserAvailabilitySettings.isEnabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }
        let (workspace, seed, local) = try workspaceWithLocalSibling()
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false, seedPanelId: seed)
        let remoteBrowser = try XCTUnwrap(workspace.newBrowserSplit(
            from: seed,
            orientation: .vertical,
            focus: false
        ))
        let localBrowser = try XCTUnwrap(workspace.newBrowserSplit(
            from: local.id,
            orientation: .vertical,
            focus: false
        ))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let restored = Workspace()
        let remap = restored.restoreSessionSnapshot(snapshot)
        let restoredSeed = try XCTUnwrap(remap[seed])
        let restoredLocal = try XCTUnwrap(remap[local.id])
        let restoredRemoteBrowser = try XCTUnwrap(remap[remoteBrowser.id])
        let restoredLocalBrowser = try XCTUnwrap(remap[localBrowser.id])

        XCTAssertEqual(restored.remoteConfiguration?.scope, .pane)
        XCTAssertTrue(restored.isRemoteTerminalSurface(restoredSeed))
        XCTAssertEqual(restored.terminalPanel(for: restoredSeed)?.surface.debugInitialCommand(), startupCommand)
        XCTAssertFalse(restored.isRemoteTerminalSurface(restoredLocal))
        XCTAssertNil(restored.terminalPanel(for: restoredLocal)?.surface.debugInitialCommand())
        XCTAssertTrue(restored.remoteScopedBrowserPanelIds.contains(restoredRemoteBrowser))
        XCTAssertFalse(restored.remoteScopedBrowserPanelIds.contains(restoredLocalBrowser))

        let restoredSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(
            restoredSnapshot.panels.first { $0.id == restoredRemoteBrowser }?.browser?.isRemoteScoped,
            true
        )
        XCTAssertNil(restoredSnapshot.panels.first { $0.id == restoredLocalBrowser }?.browser?.isRemoteScoped)
    }

    func testWorkspaceScopeStillInheritsFromAnySourcePane() throws {
        let (workspace, seed, local) = try workspaceWithLocalSibling()
        workspace.configureRemoteConnection(remoteConfiguration(scope: .workspace), autoConnect: false)

        let remoteFromSeed = try XCTUnwrap(workspace.newTerminalSplit(
            from: seed,
            orientation: .vertical,
            focus: false
        ))
        let remoteFromLocal = try XCTUnwrap(workspace.newTerminalSplit(
            from: local.id,
            orientation: .vertical,
            focus: false
        ))

        XCTAssertTrue(workspace.isRemoteTerminalSurface(remoteFromSeed.id))
        XCTAssertEqual(remoteFromSeed.surface.debugInitialCommand(), startupCommand)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(remoteFromLocal.id))
        XCTAssertEqual(remoteFromLocal.surface.debugInitialCommand(), startupCommand)
    }
}
