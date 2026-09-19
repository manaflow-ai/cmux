import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud cwd and machine identity", .serialized)
@MainActor
struct CloudDirectoryLifecycleTests {
    @Test("Terminal-only cd deltas update focused and background panels without title changes")
    func liveDirectoryDelta() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let first = fixture.panels[0]
        let second = fixture.panels[1]
        try fixture.changeDirectory("/srv/focused", terminal: 0)
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/focused")
        #expect(fixture.workspace.reportedPanelDirectory(panelId: first) == "/srv/focused")
        #expect(fixture.catalog.resources[fixture.resourceID(0)]?.detail == "/srv/focused")
        let row = CloudTreeTerminalRow(resource: try #require(fixture.catalog.resources[fixture.resourceID(0)]), isOpen: true)
        #expect(row.directoryText == "/srv/focused")
        #expect(try fixture.sidebarText().contains("focused"))

        try fixture.changeDirectory("/srv/background", terminal: 1)
        #expect(fixture.workspace.reportedPanelDirectory(panelId: second) == "/srv/background")
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/focused")
        #expect(try fixture.sidebarText().contains("background"))
        fixture.workspace.focusPanel(second)
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/background")
        #expect(fixture.workspace.title == "My explicit task title")
        #expect(try !fixture.sidebarText().contains("local-checkout"))
    }

    @Test("Remote cd updates an unselected workspace without changing selection")
    func unselectedWorkspace() throws {
        let fixture = try CloudDirectoryTestFixture()
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let selected = Workspace()
        manager.tabs = [fixture.workspace, selected]
        manager.selectedTabId = selected.id
        defer {
            fixture.close()
            for panel in selected.panels.values { panel.close() }
            manager.tabs = []
        }
        try fixture.changeDirectory("/srv/unselected", terminal: 0)
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/unselected")
        #expect(try fixture.sidebarText().contains("unselected"))
        #expect(manager.selectedTabId == selected.id)
    }

    @Test("Missing remote cwd is explicit and cannot resurrect launch, git or PR metadata")
    func missingDirectory() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.changeDirectory(nil, terminal: 0)
        try fixture.changeDirectory(nil, terminal: 1)
        let workspace = fixture.workspace
        #expect(workspace.presentedCurrentDirectory == nil)
        #expect(!workspace.updatePanelDirectory(panelId: fixture.panels[0], directory: "/Users/alice/local-checkout"))
        workspace.updatePanelGitBranch(panelId: fixture.panels[0], branch: "local-only", isDirty: true)
        workspace.updatePanelPullRequest(panelId: fixture.panels[0], number: 4, label: "PR", url: try #require(URL(string: "https://github.com/example/local/pull/4")), status: .open)
        let sidebar = try fixture.sidebar()
        #expect(sidebar.finderDirectoryPath == nil)
        #expect(sidebar.compactGitBranchSummaryText == nil)
        #expect(sidebar.pullRequestRows.isEmpty)
        let text = try fixture.sidebarText()
        #expect(text.contains("Directory unavailable"))
        #expect(!text.contains("local-checkout"))
        #expect(!text.contains("first"))
    }

    @Test("An unconfirmed Cloud terminal withholds its requested cwd until the machine's state is current")
    func unconfirmedCloudDirectoryIsWithheld() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        // A terminal the app just asked a machine for carries the requested
        // directory, but that machine's provider has not accepted any state yet.
        let unconfirmed = SurfaceMachineID.cloud("unconfirmed-machine")
        let provider = CmuxTuiSurfaceProvider(
            summary: VMSummary(id: unconfirmed.rawValue, provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil),
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }), catalog: fixture.catalog
        )
        fixture.catalog.register(provider)
        defer { fixture.catalog.unregister(machine: unconfirmed) }
        let requested = SurfaceResourceID(machine: unconfirmed, kind: .terminal, key: "term_requested")
        fixture.catalog.upsert(SurfaceResource(
            id: requested, title: "", detail: "/srv/requested", lifecycle: .launching,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        ), from: provider)
        let local = SurfaceResourceID(machine: .local, kind: .terminal, key: "local-term")
        fixture.catalog.upsert(SurfaceResource(
            id: local, title: "", detail: "/Users/alice/project", lifecycle: .running,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        ))

        let snapshot = fixture.catalog.snapshot
        let presented = try #require(snapshot.resources.first { $0.id == requested })
        #expect(presented.detail == nil)
        #expect(fixture.catalog.resources[requested]?.detail == "/srv/requested")
        let row = CloudTreeTerminalRow(
            resource: presented, isOpen: true,
            directoryIsCurrent: !snapshot.staleMachineIDs.contains(unconfirmed)
        )
        #expect(row.directoryText == "Directory unavailable")
        // Confirmed Cloud terminals and local terminals keep their directories.
        #expect(snapshot.resources.first { $0.id == fixture.resourceID(0) }?.detail == "/home/cmux/first")
        #expect(snapshot.resources.first { $0.id == local }?.detail == "/Users/alice/project")
    }

    @Test("A stale graph loses cwd trust until a fresh snapshot confirms it")
    func reconnectAndStalePublication() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let old = try #require(fixture.provider.cloudState)
        fixture.catalog.markCloudStateStale(on: fixture.machine, reason: "temporary gap")
        try fixture.changeDirectory("/srv/resumed", terminal: 0)
        #expect(fixture.workspace.reportedPanelDirectory(panelId: fixture.panels[1]) == "/home/cmux/second")
        fixture.catalog.markCloudStateStale(on: fixture.machine, reason: "reconnecting")
        #expect(fixture.workspace.presentedCurrentDirectory == nil)
        #expect(fixture.catalog.snapshot.staleMachineIDs.contains(fixture.machine))
        let row = CloudTreeTerminalRow(resource: try #require(fixture.catalog.resources[fixture.resourceID(0)]), isOpen: true, directoryIsCurrent: false)
        #expect(row.directoryText == "Directory unavailable")
        #expect(try fixture.sidebarText().contains("Directory unavailable"))
        let current = try fixture.install(paths: ["/srv/reconnected", nil], revision: 1, generation: "replacement")
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/reconnected")
        #expect(!fixture.provider.installSnapshotIfNewer(old))
        fixture.provider.publish(old, ports: [])
        fixture.provider.publishDelta(old, impact: CloudVMStateDeltaImpact(resourceIDs: [fixture.resourceID(0)], requiresFullResourceRebuild: false), ports: [], reconcileTitles: false)
        #expect(fixture.catalog.cloudStates[fixture.machine] == current)
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/reconnected")
    }

    @Test("Older and equal-cursor conflicting snapshots cannot overwrite a live cd")
    func outOfOrderReports() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let old = try #require(fixture.provider.cloudState)
        try fixture.changeDirectory("/srv/newest", terminal: 0)
        #expect(!fixture.provider.installSnapshotIfNewer(old))
        let conflict = try fixture.state(paths: ["/srv/old", nil], revision: 2)
        #expect(!fixture.provider.installSnapshotIfNewer(conflict))
        fixture.provider.publish(conflict, ports: [])
        #expect(fixture.workspace.presentedCurrentDirectory == "/srv/newest")
        #expect(CloudVMStateSyncDecision.forDelta(generation: "daemon", previousRevision: 1, revision: 2, current: fixture.provider.cloudState?.cursor) == .ignoreStale)
    }

    @Test("Machine names and stable IDs survive refresh and invalidate the immutable sidebar snapshot")
    func machineRename() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let revision = fixture.workspace.cloudBindingState.revision
        var info = fixture.provider.info
        info.name = "Build server"
        fixture.catalog.updateMachine(info, from: fixture.provider)
        let sidebar = try fixture.sidebar()
        #expect(sidebar.cloudWorkspaceLabel?.contains("Build server") == true)
        #expect(sidebar.cloudWorkspaceLabel?.contains("cwd-machine") == true)
        #expect(try fixture.sidebarText().contains("Build server ·"))
        #expect(try !fixture.sidebarText().contains("cwd-machine"))
        #expect(fixture.workspace.cloudBindingState.revision > revision)
        #expect(sidebar.accessibilityLabel(index: 0, workspaceCount: 1).contains("Build server"))
        info.name = "Renamed server"
        fixture.catalog.updateMachine(info, from: fixture.provider)
        #expect(try fixture.sidebar().cloudWorkspaceLabel?.contains("Renamed server") == true)
        #expect(try fixture.sidebar().cloudWorkspaceLabel?.contains("Build server") == false)
        #expect(fixture.workspace.title == "My explicit task title")
    }

    @Test("Every sidebar width uses the Cloud tree name, with IDs reserved for help", arguments: [
        (nil as String?, "early-plum-alpaca" as String?, "early-plum-alpaca"),
        ("Build server", "early-plum-alpaca", "Build server"),
        ("", "early-plum-alpaca", "early-plum-alpaca"),
        (nil, nil, "cwd-machine"),
        ("", "", "cwd-machine")
    ])
    func machineNamePresentation(label: String?, slug: String?, expected: String) throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let binding = fixture.workspace.cloudVMBinding
        let projections = fixture.catalog.projections
        var summary = fixture.provider.summary
        summary.displayName = label
        summary.slug = slug
        fixture.provider.update(summary: summary)
        try fixture.changeDirectory("/home/cmux/a", terminal: 0)
        try fixture.changeDirectory("/home/cmux/b", terminal: 1)

        #expect(MachineSnapshotBuilder.snapshot(from: summary).displayName == expected)
        #expect(fixture.provider.info.name == expected)
        for usesLastSegmentPath in [false, true] {
            let presentation = try #require(CloudWorkspaceSidebarPresentation(
                workspace: fixture.workspace, orderedPanelIDs: fixture.panels,
                usesLastSegmentPath: usesLastSegmentPath
            ))
            let full = "\(expected) · /home/cmux/a, /home/cmux/b"
            if usesLastSegmentPath {
                #expect(presentation.directoryCandidates.count == 2)
                #expect(presentation.directoryCandidates.first == full)
                #expect(presentation.directoryCandidates.last == "\(expected) · …/a, …/b")
            } else {
                #expect(presentation.directoryCandidates == [full])
            }
            #expect(presentation.directoryCandidates.allSatisfy { $0.hasPrefix("\(expected) · ") })
            #expect(presentation.machineLabel.contains(expected))
            #expect(presentation.machineLabel.contains(fixture.machine.rawValue))
        }
        let snapshot = try fixture.sidebar()
        let candidates = snapshot.compactDirectoryCandidates + snapshot.branchDirectoryLines.flatMap(\.directoryCandidates)
        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { $0.hasPrefix("\(expected) · ") })
        #expect(snapshot.accessibilityLabel(index: 0, workspaceCount: 1).contains(fixture.machine.rawValue))
        #expect(fixture.workspace.cloudVMBinding == binding)
        #expect(fixture.catalog.projections == projections)
    }

    @Test("A renamed machine keeps its name while cwd is unavailable and safely falls back when cleared")
    func unavailableDirectoryMachineName() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.changeDirectory(nil, terminal: 0)
        try fixture.changeDirectory(nil, terminal: 1)
        for name in ["Build server", "Renamed server", "", " \n "] {
            var info = fixture.provider.info
            info.name = name
            fixture.catalog.updateMachine(info, from: fixture.provider)
            let expected = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fixture.machine.rawValue : name
            let presentation = try #require(CloudWorkspaceSidebarPresentation(
                workspace: fixture.workspace, orderedPanelIDs: fixture.panels, usesLastSegmentPath: true
            ))
            #expect(presentation.directoryCandidates == ["\(expected) · \(CloudWorkspaceSidebarPresentation.unavailableDirectory)"])
            #expect(fixture.workspace.cloudVMID == fixture.machine.rawValue)
        }
    }

    @Test("Saved Cloud paths require fresh remote confirmation after restore")
    func sessionRestore() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let saved = fixture.workspace.sessionSnapshot(includeScrollback: false)
        let restored = Workspace(workingDirectory: "/Users/alice/launch")
        defer { for panel in restored.panels.values { panel.close() } }
        _ = restored.restoreSessionSnapshot(saved)
        #expect(restored.cloudVMID == "cwd-machine")
        #expect(restored.title == "My explicit task title")
        #expect(restored.presentedCurrentDirectory == nil)
        #expect(restored.sidebarGitBranchesInDisplayOrder().isEmpty)
    }

    @Test("A projected terminal switches machine identity and cwd together")
    func resourceProjectionChanges() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        workspace.cloudVMBinding = nil
        let other = SurfaceMachineID.cloud("other-machine")
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "other", "revision": "1"],
            "workspaces": [], "screens": [], "panes": [], "tabs": [],
            "terminals": [["id": "other", "title": "bash", "cwd": "/srv/other", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ], machine: other))
        var info = fixture.provider.info
        info.id = other
        info.name = "Other machine"
        fixture.catalog.replaceCloudState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: info)
        fixture.catalog.endProjections(panelID: fixture.panels[0], reason: .replaced)
        fixture.catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: other, kind: .terminal, key: "other"),
            workspaceID: workspace.id, panelID: fixture.panels[0]
        ))
        #expect(workspace.reportedPanelDirectory(panelId: fixture.panels[0]) == "/srv/other")
        #expect(try fixture.sidebar().cloudWorkspaceLabel?.contains("other-machine") == true)
        #expect(try fixture.sidebarText().contains("Other machine ·"))
        #expect(workspace.title == "My explicit task title")
    }

    @Test("A machine name is shown once for multiple directories and collisions stay distinct")
    func groupedMachineDirectories() throws {
        let fixture = try CloudDirectoryTestFixture()
        defer { fixture.close() }
        try fixture.changeDirectory("/home/cmux/a", terminal: 0)
        try fixture.changeDirectory("/home/cmux/b", terminal: 1)
        var info = fixture.provider.info
        info.name = "Build server"
        fixture.catalog.updateMachine(info, from: fixture.provider)
        let singleMachine = try #require(CloudWorkspaceSidebarPresentation(
            workspace: fixture.workspace, orderedPanelIDs: fixture.panels, usesLastSegmentPath: false
        ))
        #expect(singleMachine.directoryCandidates == ["Build server · /home/cmux/a, /home/cmux/b"])

        let other = SurfaceMachineID.cloud("other-machine")
        let otherPanel = try #require(fixture.workspace.newTerminalSurface(
            inPane: try #require(fixture.workspace.bonsplitController.allPaneIds.first), focus: false
        )).id
        let otherResource = SurfaceResource(
            id: SurfaceResourceID(machine: other, kind: .terminal, key: "other-terminal"),
            title: "bash", detail: "/srv/other", lifecycle: .running,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        )
        let otherProvider = CmuxTuiSurfaceProvider(
            summary: VMSummary(id: other.rawValue, provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil),
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }), catalog: fixture.catalog
        )
        fixture.catalog.register(otherProvider)
        defer {
            fixture.catalog.endProjections(panelID: otherPanel)
            fixture.catalog.unregister(machine: other)
            fixture.workspace.panels[otherPanel]?.close()
        }
        var otherInfo = otherProvider.info
        otherInfo.name = "Build server"
        fixture.catalog.updateMachine(otherInfo, from: otherProvider)
        fixture.catalog.upsert(otherResource, from: otherProvider)
        fixture.catalog.record(SurfaceProjection(resource: otherResource.id, workspaceID: fixture.workspace.id, panelID: otherPanel))
        let collision = try #require(CloudWorkspaceSidebarPresentation(
            workspace: fixture.workspace, orderedPanelIDs: fixture.workspace.sidebarOrderedPanelIds(), usesLastSegmentPath: false
        ))
        #expect(collision.directoryCandidates.first?.contains("Build server (cwd-machine) · /home/cmux/a, /home/cmux/b") == true)
        #expect(collision.directoryCandidates.first?.contains("Build server (other-machine) · /srv/other") == true)
    }

    @Test("Local renderer OSC reports cannot overwrite the accepted Cloud graph")
    func localRendererCannotClaimRemoteProvenance() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        defer { for panel in workspace.panels.values { panel.close() }; manager.tabs = [] }
        let panelID = try #require(workspace.focusedPanelId)
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "cloud-machine", isBase: false)
        workspace.updateCloudPanelDirectory(panelId: panelID, directory: "/srv/accepted")
        manager.updateReportedSurfaceDirectory(tabId: workspace.id, surfaceId: panelID, directory: "/Users/alice/launcher")
        #expect(workspace.reportedPanelDirectory(panelId: panelID) == "/srv/accepted")
    }
}
