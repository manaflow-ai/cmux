import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FileExplorerSSHRootSeedingTests: XCTestCase {
    func testFreshWorkspaceHasLocalSeedOrigin() {
        let workspace = Workspace()
        XCTAssertEqual(workspace.currentDirectoryOrigin, .localSeed)
        XCTAssertNil(workspace.fileExplorerRemoteRootPath,
                     "Local-seed currentDirectory must not be forwarded as a remote SSH root")
    }

    func testSuppliedWorkingDirectoryHasLocalKnownOrigin() {
        let workspace = Workspace(workingDirectory: "/tmp")
        XCTAssertEqual(workspace.currentDirectoryOrigin, .localKnown)
        XCTAssertNil(workspace.fileExplorerRemoteRootPath,
                     "Local-known currentDirectory must not be forwarded as a remote SSH root")
    }

    func testRemoteReportFlipsOriginAndExposesRemotePath() {
        let workspace = Workspace()
        let configuration = WorkspaceRemoteConfiguration(
            transport: .ssh,
            destination: "test-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        XCTAssertTrue(workspace.isRemoteWorkspace)

        // Stand in for the focused panel id so updatePanelDirectory updates currentDirectory.
        let panelId = UUID()
        workspace.debugSetFocusedPanelIdForTests(panelId)

        let didUpdate = workspace.updatePanelDirectory(panelId: panelId, directory: "/home/dev/proj")

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(workspace.currentDirectory, "/home/dev/proj")
        XCTAssertEqual(workspace.currentDirectoryOrigin, .remoteReport)
        XCTAssertEqual(workspace.fileExplorerRemoteRootPath, "/home/dev/proj")
    }

    func testLegacySnapshotMissingOriginDecodesAsNil() throws {
        // Old session-com.cmuxterm.app.json files do not carry currentDirectoryOrigin.
        // The decode contract is: missing field → nil; restoreSessionSnapshot then
        // coerces nil → .localSeed via `?? .localSeed` so the SSH file explorer
        // falls back to remote $HOME on legacy snapshots.
        let json = """
        {
            "processTitle": "Terminal",
            "isPinned": false,
            "currentDirectory": "/Users/legacy",
            "layout": {"type": "pane", "pane": {"panelIds": []}},
            "panels": [],
            "statusEntries": [],
            "logEntries": []
        }
        """
        let data = Data(json.utf8)
        let snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        XCTAssertNil(snapshot.currentDirectoryOrigin)
    }

    func testSSHCommandFailedErrorIncludesDetail() {
        let detail = "ls: cannot access '/Users/dev'"
        let error = FileExplorerError.sshCommandFailed(detail)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains(detail),
                      "errorDescription should embed the underlying SSH stderr; got \(description)")
    }

    func testSSHCommandFailedFallsBackToBareMessageForEmptyDetail() {
        let error = FileExplorerError.sshCommandFailed("")
        XCTAssertEqual(error.errorDescription, "SSH command failed")
    }
}
