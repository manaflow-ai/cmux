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
        let accessibilityLabel = snapshot.accessibilityLabel(index: 0, workspaceCount: 1)
        #expect(accessibilityLabel.contains("Cloud workspace on cloud-sidebar-vm"))
        #expect(!accessibilityLabel.contains("local-checkout"))
        let sidebarDecision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: nil,
            next: snapshot,
            force: false,
            contextMenuVisible: false
        )
        #expect(sidebarDecision.workspaceSnapshotStorage == snapshot)
        #expect(sidebarDecision.pendingWorkspaceSnapshot == nil)

        let manager = TabManager(
            initialWorkspaceTitle: "Cloud",
            initialWorkingDirectory: "/Users/alice/local-checkout",
            autoWelcomeIfNeeded: false
        )
        let managedWorkspace = try #require(manager.selectedWorkspace)
        let managedPanelID = try #require(managedWorkspace.focusedPanelId)
        managedWorkspace.cloudVMBinding = WorkspaceCloudVMBinding(
            vmID: "cloud-sidebar-vm", isBase: false, remoteWorkspaceID: "ws_1"
        )
        #expect(manager.gitProbeDirectory(for: managedWorkspace, panelId: managedPanelID) == nil)

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
            "workspaces": [["id": "ws_1", "name": "Cloud", "index": 0, "focused": true]],
            "screens": [], "panes": [], "tabs": [],
            "terminals": [["id": "term_1", "title": "terminal", "cwd": "/home/cloud/project", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ], machine: machine))
        let info = SurfaceMachineInfo(
            id: machine,
            name: machine.rawValue,
            status: "running",
            image: nil,
            hasDesktop: false,
            memoryMb: nil,
            diskMb: nil,
            linkState: .connected,
            linkError: nil,
            cpuPercent: nil,
            memoryUsedMb: nil,
            diskUsedMb: nil
        )
        catalog.replaceCloudState(state, resources: [resource], info: info)
        let service = CloudWorkspaceRenameService(
            environment: CloudWorkspaceRenameEnvironment(workspaces: { [workspace] })
        )
        service.reconcileRemoteState(machine: machine, state: state, catalog: catalog, observation: .current)
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

    @Test("Cloud workspaces disappear on the last terminal move or close and return on creation", arguments: [false, true])
    @MainActor
    func workspaceVisibilityFollowsDaemonChanges(incremental: Bool) throws {
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let initial = try visibilityState()
        publishVisibility(initial, to: catalog, incremental: false)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_side"])

        // Repro: the focused, empty workspace acquires a terminal, which then
        // moves into another workspace while the original daemon record survives.
        try updateVisibility([
            ["kind": "upsert", "resource": "tab", "id": "tab_new", "value": terminalTab(pane: "pane_main")],
            ["kind": "upsert", "resource": "terminal", "id": "term_new", "value": [
                "id": "term_new", "title": "New shell", "lifecycle": "running"
            ]]
        ], in: catalog, incremental: incremental)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_main", "ws_side"])
        let created = catalog.snapshot
        let localWorkspace = UUID()
        let terminalID = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_new")
        catalog.record(SurfaceProjection(
            resource: terminalID, workspaceID: localWorkspace, panelID: UUID(),
            remoteWorkspaceID: "ws_main", remoteTabID: "tab_new"
        ))
        let openRow = try #require(workspaceRows(catalog.snapshot).first { $0.searchableTitle == "main" })
        guard case .workspace(_, let workspace, let count, _, let openIn) = openRow.kind else {
            Issue.record("Expected the created workspace row")
            return
        }
        #expect(workspace.focused && count == 1 && openIn == localWorkspace)

        try updateVisibility([
            ["kind": "upsert", "resource": "tab", "id": "tab_new", "value": terminalTab(pane: "pane_side")]
        ], in: catalog, incremental: incremental)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_side"], "stale local projections and daemon focus cannot keep an empty row")
        #expect(CloudTreeNodeBuilder.structureSignature(visibilityNodes(created)) !=
            CloudTreeNodeBuilder.structureSignature(visibilityNodes(catalog.snapshot)))
        #expect(catalog.cloudStates[machine]?.workspaces.first?.focused == true)
        #expect(CloudTreeNodeBuilder.lookupRemoteWorkspace("ws_main", on: machine, snapshot: catalog.snapshot) ==
            .found(workspace, .none))

        try updateVisibility([
            ["kind": "delete", "resource": "tab", "id": "tab_existing"],
            ["kind": "delete", "resource": "terminal", "id": "term_existing"]
        ], in: catalog, incremental: incremental)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_side"], "removing one of two terminals keeps the workspace")
        try updateVisibility([
            ["kind": "delete", "resource": "tab", "id": "tab_new"]
        ], in: catalog, incremental: incremental)
        #expect(workspaceRows(catalog.snapshot).isEmpty)
        #expect(catalog.resources[terminalID]?.remoteViews == [])
        #expect(CloudTreeNodeBuilder.flattened(visibilityNodes(catalog.snapshot)).contains {
            $0.id == CloudTreeNodeBuilder.nodeID(resource: terminalID)
        }, "detaching a terminal preserves its process in the machine pool")
        #expect(catalog.cloudStates[machine]?.workspaces.count == 2)
        #expect(CloudTreeNodeBuilder.flattened(visibilityNodes(catalog.snapshot)).contains {
            $0.id == CloudTreeNodeBuilder.nodeID(workspacesPlaceholder: machine)
        })

        try updateVisibility([
            ["kind": "upsert", "resource": "tab", "id": "tab_new", "value": terminalTab(pane: "pane_main")]
        ], in: catalog, incremental: incremental)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_main"])
        let returned = try #require(catalog.resources[terminalID])
        // Terminal kill and accepted create receipts update resources before the
        // next complete graph; both must update visibility without a fleet poll.
        catalog.remove(terminalID, from: provider)
        #expect(catalog.resources[terminalID] == nil)
        #expect(workspaceRows(catalog.snapshot).isEmpty)
        catalog.upsert(returned, from: provider)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_main"])
        publishVisibility(try #require(catalog.cloudStates[machine]), to: catalog, incremental: false)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_main"], "a full refresh agrees with the event stream")
    }

    @Test("Visibility preserves workspace metadata and nonterminal content")
    @MainActor
    func nonterminalWorkspacesKeepVisiblePersistentState() throws {
        let catalog = SurfaceCatalog()
        var document = try #require(visibilityState().snapshotObject())
        document["terminals"] = [] as [[String: Any]]
        document["tabs"] = [
            ["id": "tab_docs", "pane_id": "pane_main", "content_kind": "browser", "content_id": "docs"],
            ["id": "tab_desktop", "pane_id": "pane_side", "content_kind": "display", "content_id": "display:1"]
        ]
        document["browsers"] = [["id": "docs", "tab_id": "tab_docs", "title": "Docs", "url": "https://cmux.com/docs"]]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
        publishVisibility(state, to: catalog, incremental: false)
        let before = catalog.snapshot
        #expect(workspaceIDs(catalog.snapshot) == ["ws_main", "ws_side"])
        #expect(catalog.snapshot == before && catalog.cloudStates[machine] == state, "visibility never deletes persistent state")
        #expect(try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: "ws_main").placements.count == 1)
        #expect(try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: "ws_side").placements.count == 1)
    }

    @Test("Workspace visibility counts retained and legacy terminal placements", arguments: [
        SurfaceLifecycle.launching, .running, .exited, .unavailable
    ])
    @MainActor
    func retainedAndLegacyTerminalsRemainVisible(lifecycle: SurfaceLifecycle) throws {
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        publishVisibility(try visibilityState(), to: catalog, incremental: false)
        var terminal = try #require(catalog.snapshot.resources.first { $0.kind == .terminal })
        terminal.lifecycle = lifecycle
        terminal.remoteViews = nil
        catalog.upsert(terminal, from: provider)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_side"], "retained terminal output is valid workspace content")
        terminal.remoteViews = []
        catalog.upsert(terminal, from: provider)
        #expect(catalog.resources[terminal.id]?.remoteViews == [])
        #expect(workspaceRows(catalog.snapshot).isEmpty, "explicit detachment overrides a legacy workspace hint")
    }

    private func visibilityState() throws -> CloudVMState {
        let ids = ["main", "side"]
        let document: [String: Any] = [
            "cursor": ["generation": "visibility", "revision": "1"],
            "workspaces": ids.enumerated().map {
                ["id": "ws_\($0.element)", "name": $0.element, "index": $0.offset, "focused": $0.offset == 0] as [String: Any]
            },
            "screens": ids.map { ["id": "screen_\($0)", "workspace_id": "ws_\($0)"] },
            "panes": ids.map { ["id": "pane_\($0)", "screen_id": "screen_\($0)"] },
            "tabs": [["id": "tab_existing", "pane_id": "pane_side", "content_kind": "terminal", "content_id": "term_existing"]],
            "terminals": [["id": "term_existing", "title": "Existing shell", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
    }

    private func terminalTab(pane: String) -> [String: Any] {
        ["id": "tab_new", "pane_id": pane, "content_kind": "terminal", "content_id": "term_new"]
    }

    @MainActor
    private func updateVisibility(_ changes: [[String: Any]], in catalog: SurfaceCatalog, incremental: Bool) throws {
        let previous = try #require(catalog.cloudStates[machine])
        let cursor = try #require(previous.cursor)
        let next = CloudVMCursor(generation: cursor.generation, revision: cursor.revision + 1)
        let delta: [String: Any] = [
            "kind": "delta", "previous_revision": String(cursor.revision), "revision": String(next.revision),
            "changes": changes
        ]
        let state = try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: JSONSerialization.data(withJSONObject: delta), cursor: next, to: previous
        ))
        publishVisibility(state, to: catalog, incremental: incremental)
    }

    @MainActor
    private func publishVisibility(_ state: CloudVMState, to catalog: SurfaceCatalog, incremental: Bool) {
        let info = SurfaceMachineInfo(
            id: machine, name: machine.rawValue, status: "running", image: nil, hasDesktop: true,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: state.workspaces.map {
                SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
            }
        )
        let resources = CmuxTuiSnapshotParser.resources(from: state)
        if incremental { catalog.applyCloudStateDelta(state, resources: resources, info: info) }
        else { catalog.replaceCloudState(state, resources: resources, info: info) }
    }

    private func visibilityNodes(_ snapshot: SurfaceCatalogSnapshot) -> [CloudTreeNode] {
        CloudTreeNodeBuilder.nodes(machines: [], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false)
    }

    private func workspaceRows(_ snapshot: SurfaceCatalogSnapshot) -> [CloudTreeNode] {
        CloudTreeNodeBuilder.flattened(visibilityNodes(snapshot)).filter { $0.structureTag == "workspace" }
    }

    private func workspaceIDs(_ snapshot: SurfaceCatalogSnapshot) -> [String] {
        workspaceRows(snapshot).compactMap {
            if case .workspace(_, let workspace, _, _, _) = $0.kind { return workspace.id }
            return nil
        }
    }
}
