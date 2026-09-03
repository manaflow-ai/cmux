import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Cloud sidebar's model is one big machine hosting MANY cmux-tui
/// workspaces (the shape cmux Cloud had on Blaxel, now on Freestyle) — never
/// "one VM = one workspace". These pin what the outline builds for such a
/// machine — its four groups, in this order: **Workspaces** (the machine's
/// face, always its own row with its own "+", one row per workspace with the
/// terminals in its layout), **Terminals** (every terminal the machine owns,
/// one row per identity, always present so its "+" is New Terminal), **Ports**,
/// and **VNC Displays** (one row per screen).
///
/// Regression (https://github.com/manaflow-ai/cmux/issues/11762): a machine
/// with a single workspace used to fold the group into the workspace row
/// ("Workspaces / main"), which hid the group and its "+" exactly on the fresh
/// machine where a person creates their second workspace — the tree read as
/// "this machine is one workspace".
@Suite("Cloud tree: one machine, many workspaces")
struct CloudTreeOneMachineManyWorkspacesTests {
    private let machineID = "brave-otter"
    private var machine: SurfaceMachineID { .cloud(machineID) }

    private func fleetRow() -> MachineSnapshot {
        MachineSnapshot(
            id: machineID,
            provider: "freestyle",
            image: "sh-08be343bf2b54b4bb0e5226b97eaa6c4",
            isDesktop: false,
            activity: .ready,
            createdAt: nil,
            label: "Big Machine"
        )
    }

    private func info(workspaces: [SurfaceRemoteWorkspace], hasDesktop: Bool = false) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machine, name: "Big Machine", status: "running", image: "sh-08be343bf2b54b4bb0e5226b97eaa6c4",
            hasDesktop: hasDesktop, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: workspaces
        )
    }

    private func workspace(_ id: String, _ name: String, index: Int, focused: Bool = false) -> SurfaceRemoteWorkspace {
        SurfaceRemoteWorkspace(id: id, name: name, index: index, focused: focused)
    }

    /// A terminal viewed in `workspaces` (a daemon tab in each); none = alive in the pool only.
    private func terminal(_ key: String, title: String = "bash", in workspaces: [SurfaceRemoteWorkspace]) -> SurfaceResource {
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: "/root",
            lifecycle: .running, agent: nil, remoteWorkspace: workspaces.first, port: nil, url: nil
        )
        resource.remoteViews = workspaces.enumerated().map { SurfaceRemoteView(tabID: "tab_\(key)_\($0.offset)", workspace: $0.element) }
        return resource
    }

    private func display(in workspaces: [SurfaceRemoteWorkspace]) -> SurfaceResource {
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .display, key: SurfaceResourceID.desktopDisplayKey), title: "Desktop", detail: nil,
            lifecycle: .running, agent: nil, remoteWorkspace: workspaces.first, port: 6901, url: nil
        )
        resource.remoteViews = workspaces.enumerated().map { SurfaceRemoteView(tabID: "tab_desk_\($0.offset)", workspace: $0.element) }
        return resource
    }

    private func rows(_ snapshot: SurfaceCatalogSnapshot) -> [CloudTreeNode] {
        CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [fleetRow()], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false
        ))
    }

    @Test("A machine with a single workspace keeps its Workspaces group row and the group's +")
    func singleWorkspaceKeepsItsGroupRow() throws {
        let main = workspace("ws_main", "main", index: 0, focused: true)
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(workspaces: [main])],
            resources: [terminal("term_1", in: [main])],
            projections: []
        )
        let tree = rows(snapshot)
        #expect(tree.map(\.id) == [
            "machine:brave-otter",
            "machine:brave-otter/workspaces",
            "machine:brave-otter/ws/ws_main",
            "machine:brave-otter/ws/ws_main/resource:brave-otter/terminal/term_1",
        ], "the group is its own row above the lone workspace — never folded into it")
        let group = try #require(tree.first { $0.id == "machine:brave-otter/workspaces" })
        #expect(group.structureTag == "workspacesGroup")
        #expect(CloudTreeRowHoverButtons.hasButtons(for: group.kind), "the group's hover + (New Workspace) stays reachable on a one-workspace machine")
        let row = try #require(tree.first { $0.id == "machine:brave-otter/ws/ws_main" })
        #expect(row.searchableTitle == "main", "the workspace row carries its own name, not a 'Workspaces / main' breadcrumb")
        #expect(!row.isMachineRow, "a workspace is a row under its machine, never a machine of its own")
    }

    @Test("Under a connected machine: Workspaces, then Terminals (every terminal), Ports, VNC Displays")
    func workspacesThenTerminalsPortsDisplays() throws {
        let main = workspace("ws_main", "main", index: 0, focused: true)
        let side = workspace("ws_side", "side", index: 1)
        let shared = terminal("term_shared", title: "tail -f", in: [main, side])
        let detached = terminal("term_3", title: "sleep", in: [])
        let desktop = display(in: [side])
        let port = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .browser, key: "port:3000"), title: ":3000", detail: "http",
            lifecycle: .running, agent: nil, remoteWorkspace: nil, port: 3000, url: nil
        )
        let docs = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .browser, key: "docs"), title: "Docs", detail: nil,
            lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: "https://cmux.com/docs"
        )
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(workspaces: [main, side], hasDesktop: true)],
            resources: [terminal("term_1", in: [main]), terminal("term_2", in: [side]), detached, shared, desktop, port, docs],
            projections: []
        )
        let tree = rows(snapshot)
        #expect(tree.map(\.id) == [
            "machine:brave-otter",
            "machine:brave-otter/workspaces",
            "machine:brave-otter/ws/ws_main",
            "machine:brave-otter/ws/ws_main/resource:brave-otter/terminal/term_1",
            "machine:brave-otter/ws/ws_main/resource:brave-otter/terminal/term_shared",
            "machine:brave-otter/ws/ws_main/resource:brave-otter/display/display:1",
            "machine:brave-otter/ws/ws_side",
            "machine:brave-otter/ws/ws_side/resource:brave-otter/terminal/term_2",
            "machine:brave-otter/ws/ws_side/resource:brave-otter/terminal/term_shared",
            "machine:brave-otter/ws/ws_side/resource:brave-otter/display/display:1",
            "machine:brave-otter/terminals",
            "resource:brave-otter/terminal/term_1",
            "resource:brave-otter/terminal/term_2",
            "resource:brave-otter/terminal/term_3",
            "resource:brave-otter/terminal/term_shared",
            "machine:brave-otter/ports",
            "resource:brave-otter/browser/port:3000",
            "machine:brave-otter/displays",
            "resource:brave-otter/display/display:1",
        ], "the machine's four groups in order; a daemon browser in no workspace gets no group of its own")
        let byID = Dictionary(tree.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Terminals lists every terminal the machine owns, one row per identity — the
        // workspace rows are pointers into it — badged with its daemon-tab count.
        guard case .terminalsPool(_, let poolCount) = try #require(byID["machine:brave-otter/terminals"]).kind else {
            Issue.record("expected the Terminals group"); return
        }
        #expect(poolCount == 4)
        guard case .terminal(let sharedRow) = try #require(byID["resource:brave-otter/terminal/term_shared"]).kind,
              case .terminal(let detachedRow) = try #require(byID["resource:brave-otter/terminal/term_3"]).kind else {
            Issue.record("expected both pool rows"); return
        }
        #expect(sharedRow.viewBadge == 2, "a tab in each of two workspaces")
        #expect(detachedRow.viewBadge == 0, "no tab shows it: still running, listed in the pool")
        // A terminal viewed in two workspaces shows under both; each row counts its own.
        guard case .workspace(_, _, let mainCount, _) = try #require(byID["machine:brave-otter/ws/ws_main"]).kind,
              case .workspace(_, _, let sideCount, _) = try #require(byID["machine:brave-otter/ws/ws_side"]).kind else {
            Issue.record("expected both workspace rows"); return
        }
        #expect(mainCount == 2)
        #expect(sideCount == 2)
        // The pinned display travels with its workspace's open/drag group; the implicit one does not.
        #expect(byID["machine:brave-otter/ws/ws_side"]?.dragGroup?.resources == [
            SurfaceResourceID(machine: machine, kind: .terminal, key: "term_2"), shared.id, desktop.id,
        ])
        #expect(byID["machine:brave-otter/ws/ws_main"]?.dragGroup?.resources == [
            SurfaceResourceID(machine: machine, kind: .terminal, key: "term_1"), shared.id,
        ])
        // VNC Displays is one row per screen; the group is searchable under that name.
        #expect(byID["machine:brave-otter/displays"]?.searchableTitle == "VNC Displays")
    }

    @Test("An empty machine still offers its Workspaces and Terminals groups: their + make the first ones")
    func emptyMachineKeepsItsGroups() throws {
        let snapshot = SurfaceCatalogSnapshot(machines: [info(workspaces: [])], resources: [], projections: [])
        let tree = rows(snapshot)
        #expect(tree.map(\.id) == [
            "machine:brave-otter",
            "machine:brave-otter/workspaces",
            "machine:brave-otter/workspaces/placeholder",
            "machine:brave-otter/terminals",
            "machine:brave-otter/terminals/placeholder",
        ])
        for groupID in ["machine:brave-otter/workspaces", "machine:brave-otter/terminals"] {
            let group = try #require(tree.first { $0.id == groupID })
            #expect(CloudTreeRowHoverButtons.hasButtons(for: group.kind), "\(groupID) keeps its hover +")
        }
        let placeholders = tree.filter { $0.structureTag == "placeholder" }
        #expect(placeholders.map(\.searchableTitle) == ["No workspaces yet", "No terminals yet"])
        #expect(placeholders.allSatisfy { $0.machine == machine })
        for row in placeholders {
            guard case .placeholder(_, let placeholder) = row.kind else { Issue.record("expected a placeholder"); continue }
            #expect(placeholder.style == .dimmed)
        }
    }

    @Test("Several workspaces on one machine each list their own terminals under the one machine row")
    func manyWorkspacesOnOneMachine() throws {
        let workspaces = (0..<3).map { workspace("ws_\($0)", "task-\($0)", index: $0, focused: $0 == 0) }
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(workspaces: workspaces)],
            resources: workspaces.map { terminal("term_\($0.index)", in: [$0]) },
            projections: []
        )
        let tree = rows(snapshot)
        #expect(tree.filter(\.isMachineRow).map(\.id) == ["machine:brave-otter"], "one machine row hosts every workspace")
        let workspaceRows = tree.filter { $0.structureTag == "workspace" }
        #expect(workspaceRows.map(\.searchableTitle) == ["task-0", "task-1", "task-2"], "daemon order, every workspace present")
        #expect(workspaceRows.allSatisfy { $0.machine == machine })
        #expect(workspaceRows.map(\.children.count) == [1, 1, 1], "each workspace lists its own terminal")
        let pool = try #require(tree.first { $0.structureTag == "terminalsPool" })
        #expect(pool.children.map(\.id) == [
            "resource:brave-otter/terminal/term_0",
            "resource:brave-otter/terminal/term_1",
            "resource:brave-otter/terminal/term_2",
        ], "Terminals lists every terminal once, whatever workspace shows it")
    }

    @Test("`vm workspace open` resolves a workspace the way its row does: by id, by unique name, every view counted")
    func lookupMatchesTheRow() throws {
        let main = workspace("ws_main", "main", index: 0, focused: true)
        let side = workspace("ws_side", "side", index: 1)
        // First view in main, second in side: it belongs to both.
        let shared = terminal("term_shared", in: [main, side])
        let only = terminal("term_side", in: [side])
        let desktop = display(in: [side])
        let snapshot = SurfaceCatalogSnapshot(machines: [info(workspaces: [main, side])], resources: [shared, only, desktop], projections: [])
        guard case .found(let found, let members) = CloudTreeNodeBuilder.lookupRemoteWorkspace("ws_side", on: machine, snapshot: snapshot) else {
            Issue.record("expected ws_side by id"); return
        }
        #expect(found == side)
        #expect(members.ids == [shared.id, only.id, desktop.id], "terminals in catalog order — the shared one included — then the pinned display")
        #expect(CloudTreeNodeBuilder.lookupRemoteWorkspace("side", on: machine, snapshot: snapshot) == .found(side, members), "an unambiguous name resolves too")
        let row = try #require(rows(snapshot).first { $0.id == "machine:brave-otter/ws/ws_side" })
        #expect(row.dragGroup?.resources == members.ids, "one set for the click, the drop, and `vm workspace open`")
        #expect(CloudTreeNodeBuilder.lookupRemoteWorkspace("nope", on: machine, snapshot: snapshot) == .notFound)
    }

    @Test("An existing but empty workspace resolves with nothing to open; duplicate names need an id")
    func emptyAndAmbiguousWorkspaces() {
        let scratchA = workspace("ws_a", "scratch", index: 0)
        let scratchB = workspace("ws_b", "scratch", index: 1)
        let snapshot = SurfaceCatalogSnapshot(machines: [info(workspaces: [scratchA, scratchB])], resources: [], projections: [])
        #expect(
            CloudTreeNodeBuilder.lookupRemoteWorkspace("ws_b", on: machine, snapshot: snapshot)
                == .found(scratchB, CloudTreeRemoteWorkspaceMembers(terminals: [], browsers: [], displays: [])),
            "the machine lists it, so it exists — with nothing in it"
        )
        #expect(CloudTreeNodeBuilder.lookupRemoteWorkspace("scratch", on: machine, snapshot: snapshot) == .ambiguous([scratchA, scratchB]))
        // The rows agree: both scratch workspaces show under the one machine, each empty.
        #expect(rows(snapshot).filter { $0.structureTag == "workspace" }.map(\.children.count) == [0, 0])
    }
}
