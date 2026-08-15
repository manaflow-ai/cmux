import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace git diff directory resolver")
struct WorkspaceGitDiffDirectoryResolverTests {
    @MainActor
    @Test("local focused panel resolves to its tracked directory")
    func localFocusedPanelUsesItsTrackedDirectory() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/development")
        let panelId = try #require(workspace.focusedPanelId)
        workspace.panelDirectories[panelId] = "/Users/alice/project"
        let resolver = WorkspaceGitDiffDirectoryResolver()
        #expect(resolver.resolvedDirectory(for: workspace, focusedPanelId: panelId) == "/Users/alice/project")
    }

    @MainActor
    @Test("remote workspace resolves to nil")
    func remoteWorkspaceResolvesNil() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/development")
        workspace.remoteConfiguration = sshRemoteConfiguration()
        workspace.currentDirectory = "/home/remote/workspace"
        let resolver = WorkspaceGitDiffDirectoryResolver()
        #expect(resolver.resolvedDirectory(for: workspace, focusedPanelId: workspace.focusedPanelId) == nil)
    }

    @MainActor
    @Test("focused remote terminal panel resolves to nil")
    func focusedRemoteTerminalPanelResolvesNil() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/development")
        let panelId = try #require(workspace.focusedPanelId)
        workspace.panelDirectories[panelId] = "/Users/alice/project"
        workspace.activeRemoteTerminalSurfaceIds.insert(panelId)
        let resolver = WorkspaceGitDiffDirectoryResolver()
        #expect(resolver.resolvedDirectory(for: workspace, focusedPanelId: panelId) == nil)
    }

    @MainActor
    @Test("no focused panel falls back to current directory")
    func noFocusedPanelFallsBackToCurrentDirectory() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/development")
        workspace.currentDirectory = "/Users/alice/workspace"
        let resolver = WorkspaceGitDiffDirectoryResolver()
        #expect(resolver.resolvedDirectory(for: workspace, focusedPanelId: nil) == "/Users/alice/workspace")
    }

    private func sshRemoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "seepine@192.168.5.20",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: "relay-\(UUID().uuidString)",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-gitdiff-\(UUID().uuidString).sock",
            terminalStartupCommand: "ssh seepine@192.168.5.20"
        )
    }
}
