import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud sidebar surface lifecycle")
struct CloudSidebarSurfaceRegressionTests {
    private let machine = SurfaceMachineID.cloud("sidebar-vm")

    @Test("Cloud-bound workspaces never use local sidebar provenance")
    @MainActor
    func cloudBindingRejectsLocalDirectoryAndGitStateIncludingRestore() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/local-checkout")
        let panelID = try #require(workspace.focusedPanelId)
        workspace.updatePanelGitBranch(panelId: panelID, branch: "local-only", isDirty: true)
        workspace.updatePanelPullRequest(
            panelId: panelID, number: 4, label: "PR", url: try #require(URL(string: "https://github.com/example/local/pull/4")), status: .open
        )
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(
            vmID: "cloud-sidebar-vm", isBase: false, remoteWorkspaceID: "ws_1"
        )
        #expect(workspace.usesRemoteDirectoryProvenance)
        #expect(!workspace.allowsLocalDirectoryFallback(panelId: panelID))
        #expect(!workspace.updatePanelDirectory(panelId: panelID, directory: "/Users/alice/local-checkout"))
        #expect(workspace.effectivePanelDirectory(panelId: panelID) == nil)
        workspace.updatePanelGitBranch(panelId: panelID, branch: "local-only", isDirty: true)
        #expect(workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: [panelID]).isEmpty)
        #expect(workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [panelID]).isEmpty)
        let defaults = try #require(UserDefaults(suiteName: "cloud-sidebar-\(UUID())"))
        let snapshot = SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: SidebarTabItemSettingsSnapshot(defaults: defaults), showsAgentActivity: false
        ).makeSnapshot()
        #expect(snapshot.compactDirectoryCandidates.isEmpty)
        #expect(snapshot.compactGitBranchSummaryText == nil)
        #expect(snapshot.branchDirectoryLines.isEmpty)
        #expect(snapshot.pullRequestRows.isEmpty)
        #expect(snapshot.finderDirectoryPath == nil)

        let restored = Workspace()
        _ = restored.restoreSessionSnapshot(workspace.sessionSnapshot(includeScrollback: false))
        let restoredPanelID = try #require(restored.focusedPanelId)
        #expect(restored.usesRemoteDirectoryProvenance)
        #expect(restored.terminalPanel(for: restoredPanelID)?.requestedWorkingDirectory == nil)
        #expect(restored.effectivePanelDirectory(panelId: restoredPanelID) == nil)
        #expect(restored.sidebarGitBranchesInDisplayOrder(orderedPanelIds: [restoredPanelID]).isEmpty)
    }

    @Test("a projected cloud panel cannot reuse local metadata after its remote cwd arrives")
    @MainActor
    func projectedPanelRejectsLocalMetadataWithoutWorkspaceBinding() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/local-checkout")
        let panelID = try #require(workspace.focusedPanelId)
        workspace.updatePanelGitBranch(panelId: panelID, branch: "local-only", isDirty: true)
        let remoteMachine = SurfaceMachineID.cloud("sidebar-test-\(UUID())")
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: remoteMachine, kind: .terminal, key: "term_1"),
            title: "terminal", detail: nil, lifecycle: .running,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        )
        let catalog = SurfaceCatalog.shared
        catalog.upsert(resource)
        catalog.record(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: panelID))
        defer {
            catalog.endProjections(panelID: panelID)
            catalog.remove(resource.id)
        }
        #expect(workspace.cloudVMBinding == nil)
        #expect(workspace.usesRemoteDirectoryProvenance)
        #expect(!workspace.allowsLocalDirectoryFallback(panelId: panelID))
        #expect(workspace.effectivePanelDirectory(panelId: panelID) == nil)
        workspace.updateRemotePanelDirectory(panelId: panelID, directory: "/home/cloud/project")
        #expect(workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: [panelID]).isEmpty)
    }

    @Test("daemon cwd enters the trusted remote directory path")
    @MainActor
    func daemonCwdIsPresentedForCloudProjection() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/local-checkout")
        let panelID = try #require(workspace.focusedPanelId)
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_1")
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_1"),
            title: "terminal", detail: "/home/cloud/project", lifecycle: .running,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        )
        let catalog = SurfaceCatalog()
        catalog.upsert(resource)
        catalog.record(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: panelID))
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "workspaces": [], "screens": [], "panes": [], "tabs": [],
            "terminals": [["id": "term_1", "title": "terminal", "cwd": "/home/cloud/project", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ], machine: machine))
        let service = CloudWorkspaceRenameService(
            environment: CloudWorkspaceRenameEnvironment(workspaces: { [workspace] })
        )
        service.reconcileRemoteState(machine: machine, state: state, catalog: catalog)
        #expect(workspace.reportedPanelDirectory(panelId: panelID) == "/home/cloud/project")
        #expect(workspace.presentedCurrentDirectory == "/home/cloud/project")
    }

    private func nodes(link: SurfaceLinkState?, desktop: Bool = true) -> [CloudTreeNode] {
        let row = MachineSnapshot(
            id: machine.rawValue, provider: "freestyle", image: "desktop",
            isDesktop: desktop, activity: .ready, createdAt: nil, label: nil
        )
        let info = link.map {
            SurfaceMachineInfo(
                id: machine, name: machine.rawValue, status: "running", image: "desktop",
                hasDesktop: desktop, memoryMb: nil, diskMb: nil, linkState: $0,
                linkError: $0 == .error ? "Connection failed" : nil,
                cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
            )
        }
        return CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [row],
            snapshot: SurfaceCatalogSnapshot(machines: info.map { [$0] } ?? [], resources: [], projections: []),
            localWorkspaces: [], includeLocalMachine: false
        ))
    }

    @Test("Fleet discovery never leaves a childless machine before registration")
    func awaitingProviderHasLoadingRow() {
        #expect(nodes(link: nil).contains {
            if case .placeholder(_, let value) = $0.kind { return value.style == .connecting }
            return false
        })
    }

    @Test("Desktop capability remains visible before the terminal snapshot", arguments: [SurfaceLinkState.connecting, .error, .asleep, .connected])
    func desktopBeforeSessionSnapshot(link: SurfaceLinkState) {
        #expect(nodes(link: link).contains {
            if case .display(let resource, _, _) = $0.kind { return resource.id.key == SurfaceResourceID.desktopDisplayKey }
            return false
        })
    }

    @Test("Ports distinguish loading, error, asleep, and a successful empty scan", arguments: [SurfaceLinkState.connecting, .error, .asleep, .connected])
    func emptyPortsStayVisible(link: SurfaceLinkState) throws {
        let group = try #require(nodes(link: link, desktop: false).first {
            if case .portsGroup = $0.kind { return true }
            return false
        })
        #expect(group.children.count == 1)
        guard case .placeholder(_, let value) = group.children[0].kind else {
            Issue.record("Ports must explain why there are no rows")
            return
        }
        if link == .connecting { #expect(value.style == .connecting) }
        if link == .error { #expect(value.style == .error) }
    }

    @Test("Shell-only machines do not invent a desktop")
    func noDesktopForBaseMachine() {
        #expect(!nodes(link: .connected, desktop: false).contains {
            if case .display = $0.kind { return true }
            return false
        })
    }
}
