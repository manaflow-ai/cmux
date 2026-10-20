import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct WorkspaceTerminalWorkingDirectoryFallbackTests {
    @Test func missingLocalRestoreDirectoryUsesItsNearestExistingParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-missing-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingSavedDirectory = root
            .appendingPathComponent("deleted-worktree", isDirectory: true)
            .appendingPathComponent("project", isDirectory: true)
            .path
        let selectedWorkspaceDirectory = root
            .appendingPathComponent("selected-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedWorkspaceDirectory, withIntermediateDirectories: true)

        let resolved = RemoteTerminalWorkingDirectoryResolver.resolve(
            requested: missingSavedDirectory,
            preserveExact: false,
            rescued: nil,
            panelDirectory: missingSavedDirectory,
            requestedPanelDirectory: nil,
            remoteInitialDirectory: nil,
            currentDirectory: selectedWorkspaceDirectory.path
        )

        #expect(resolved == root.path)
        #expect(resolved != selectedWorkspaceDirectory.path)

        let rescuedDirectory = root.appendingPathComponent("rescued-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: rescuedDirectory, withIntermediateDirectories: true)
        let rescued = RemoteTerminalWorkingDirectoryResolver.resolve(
            requested: missingSavedDirectory,
            preserveExact: false,
            rescued: rescuedDirectory.path,
            panelDirectory: missingSavedDirectory,
            requestedPanelDirectory: nil,
            remoteInitialDirectory: nil,
            currentDirectory: selectedWorkspaceDirectory.path
        )
        #expect(rescued == rescuedDirectory.path)
    }

    @Test func remoteRestorePreservesAnExactMissingDirectory() {
        let missingRemoteDirectory = "/home/cmux/deleted-worktree/project"
        let resolved = RemoteTerminalWorkingDirectoryResolver.resolve(
            requested: missingRemoteDirectory,
            preserveExact: true,
            rescued: nil,
            panelDirectory: nil,
            requestedPanelDirectory: nil,
            remoteInitialDirectory: nil,
            currentDirectory: "/Users/selected"
        )

        #expect(resolved == missingRemoteDirectory)
    }

    @Test func newTerminalSurfaceFallsBackToRequestedWorkingDirectoryWhenReportedDirectoryIsStale() throws {
        let workspace = Workspace()
        let sourcePaneId = try #require(
            workspace.bonsplitController.focusedPaneId,
            "Expected focused pane in new workspace"
        )

        let staleCurrentDirectory = workspace.currentDirectory
        let requestedDirectory = "/tmp/cmux-requested-tab-cwd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: requestedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: requestedDirectory) }
        let sourcePanel = try #require(
            workspace.newTerminalSurface(
                inPane: sourcePaneId,
                focus: true,
                workingDirectory: requestedDirectory
            ),
            "Expected source terminal panel to be created"
        )

        #expect(sourcePanel.requestedWorkingDirectory == requestedDirectory)
        #expect(
            workspace.panelDirectories[sourcePanel.id] == nil,
            "Expected requested cwd to exist before shell integration reports a live cwd"
        )
        #expect(
            workspace.currentDirectory == staleCurrentDirectory,
            "Expected focused workspace cwd to remain stale before panel directory updates"
        )

        let newTabPanel = try #require(
            workspace.newTerminalSurfaceInFocusedPane(focus: false),
            "Expected new terminal tab panel to be created"
        )

        #expect(
            newTabPanel.requestedWorkingDirectory == requestedDirectory,
            "Expected new terminal tab to inherit the selected source terminal's requested cwd when no reported cwd exists yet"
        )
    }
}
