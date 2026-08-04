import CmuxSidebar
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
@MainActor
struct WorkspaceRepositorySidebarTests {
    @Test
    func snapshotProjectsFocusedPanelRepositoryLink() throws {
        let workspace = Workspace(title: "Repository workspace")
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let focusedLink = try Self.repositoryLink(
            remoteName: "origin",
            displayName: "manaflow-ai/cmux",
            destination: "https://github.com/manaflow-ai/cmux"
        )
        let otherLink = try Self.repositoryLink(
            remoteName: "upstream",
            displayName: "upstream/cmux",
            destination: "https://github.com/upstream/cmux"
        )
        workspace.panelRepositoryLinks[UUID()] = otherLink
        workspace.updatePanelRepositoryLink(panelId: focusedPanelId, link: focusedLink)

        let snapshot = Self.snapshot(for: workspace)

        #expect(snapshot.repositoryLink == SidebarWorkspaceSnapshotBuilder.RepositoryLinkDisplay(
            remoteName: "origin",
            displayName: "manaflow-ai/cmux",
            url: URL(string: "https://github.com/manaflow-ai/cmux")!
        ))
    }

    @Test
    func snapshotHidesRepositoryLinkWhenBranchDirectoryDetailsAreHidden() throws {
        let workspace = Workspace(title: "Repository workspace")
        let focusedPanelId = try #require(workspace.focusedPanelId)
        workspace.updatePanelRepositoryLink(
            panelId: focusedPanelId,
            link: try Self.repositoryLink(
                remoteName: "origin",
                displayName: "manaflow-ai/cmux",
                destination: "https://github.com/manaflow-ai/cmux"
            )
        )

        #expect(Self.snapshot(for: workspace, showsBranchDirectory: false).repositoryLink == nil)
    }

    @Test
    func snapshotHidesRepositoryLinkForRemoteWorkspace() throws {
        let workspace = Workspace(title: "Remote repository workspace")
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "wss://remote.example.test",
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
        let focusedPanelId = try #require(workspace.focusedPanelId)
        workspace.updatePanelRepositoryLink(
            panelId: focusedPanelId,
            link: try Self.repositoryLink(
                remoteName: "origin",
                displayName: "manaflow-ai/cmux",
                destination: "https://github.com/manaflow-ai/cmux"
            )
        )

        #expect(Self.snapshot(for: workspace).repositoryLink == nil)
    }

    @Test
    func snapshotHidesRepositoryLinkForRemoteTmuxMirror() throws {
        let workspace = Workspace(title: "Remote tmux repository workspace")
        workspace.isRemoteTmuxMirror = true
        let focusedPanelId = try #require(workspace.focusedPanelId)
        workspace.updatePanelRepositoryLink(
            panelId: focusedPanelId,
            link: try Self.repositoryLink(
                remoteName: "origin",
                displayName: "manaflow-ai/cmux",
                destination: "https://github.com/manaflow-ai/cmux"
            )
        )

        #expect(Self.snapshot(for: workspace).repositoryLink == nil)
    }

    @Test
    func repositoryActionTargetsClickedWorkspaceBrowserBeforeFallback() throws {
        let clickedWorkspaceId = UUID()
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux"))
        var acceptsBrowserOpen = true
        var routedWorkspaceIds: [UUID] = []
        var events: [String] = []
        let action = SidebarWorkspaceRowActions.repositoryAction(
            workspaceId: clickedWorkspaceId,
            openInWorkspace: { workspaceId, destination in
                routedWorkspaceIds.append(workspaceId)
                events.append("browser:\(destination.absoluteString)")
                return acceptsBrowserOpen
            },
            openExternally: { destination in
                events.append("external:\(destination.absoluteString)")
            }
        )

        action(url)
        #expect(routedWorkspaceIds == [clickedWorkspaceId])
        #expect(events == ["browser:https://github.com/manaflow-ai/cmux"])

        acceptsBrowserOpen = false
        action(url)
        #expect(routedWorkspaceIds == [clickedWorkspaceId, clickedWorkspaceId])
        #expect(events == [
            "browser:https://github.com/manaflow-ai/cmux",
            "browser:https://github.com/manaflow-ai/cmux",
            "external:https://github.com/manaflow-ai/cmux",
        ])
    }

    private static func snapshot(
        for workspace: Workspace,
        showsBranchDirectory: Bool = true
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let defaults = UserDefaults(suiteName: "WorkspaceRepositorySidebarTests.\(UUID().uuidString)")!
        defaults.set(
            showsBranchDirectory,
            forKey: SidebarWorkspaceDetailDefaults.showBranchDirectoryKey
        )
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        return SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: false
        ).makeSnapshot()
    }

    private static func repositoryLink(
        remoteName: String,
        displayName: String,
        destination: String
    ) throws -> SidebarRepositoryLinkState {
        SidebarRepositoryLinkState(
            remoteName: remoteName,
            displayName: displayName,
            url: try #require(URL(string: destination))
        )
    }
}
