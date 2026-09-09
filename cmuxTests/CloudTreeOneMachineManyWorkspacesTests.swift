import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class CloudTreeCLIBundleToken: NSObject {}

private struct CloudTreeCLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let requests: [String]
}

/// The Cloud sidebar's model is one big machine hosting MANY cmux-tui
/// workspaces (the shape cmux Cloud had on Blaxel, now on Freestyle) — never
/// "one VM = one workspace". These pin what the outline builds for such a
/// machine — its four groups, in this order: **Workspaces** (the machine's
/// face, always its own row with its own "+", one row per workspace with the
/// terminals in its layout), **Ports**, **VNC Displays** (one row per screen),
/// and last, its own section, **Terminals** (every terminal the machine owns,
/// one row per identity, always present so its "+" is New Terminal).
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

    private func info(
        workspaces: [SurfaceRemoteWorkspace],
        hasDesktop: Bool = false,
        linkState: SurfaceLinkState = .connected
    ) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machine, name: "Big Machine", status: "running", image: "sh-08be343bf2b54b4bb0e5226b97eaa6c4",
            hasDesktop: hasDesktop, memoryMb: nil, diskMb: nil, linkState: linkState, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: workspaces
        )
    }

    private func workspace(_ id: String, _ name: String, index: Int, focused: Bool = false) -> SurfaceRemoteWorkspace {
        SurfaceRemoteWorkspace(id: id, name: name, index: index, focused: focused)
    }

    /// A terminal viewed in `workspaces` (a daemon tab in each); none = alive in the pool only.
    private func terminal(
        _ key: String,
        title: String = "bash",
        lifecycle: SurfaceLifecycle = .running,
        in workspaces: [SurfaceRemoteWorkspace]
    ) -> SurfaceResource {
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: "/root",
            lifecycle: lifecycle, agent: nil, remoteWorkspace: workspaces.first, port: nil, url: nil
        )
        resource.remoteViews = workspaces.enumerated().map { SurfaceRemoteView(tabID: "tab_\(key)_\($0.offset)", workspace: $0.element) }
        return resource
    }

    /// A terminal shown by one tab of pane `paneID` in `workspace`: `index` is the tab's
    /// position in that pane, `focused` whether the pane currently shows it.
    private func tabbedTerminal(
        _ key: String,
        title: String = "bash",
        in workspace: SurfaceRemoteWorkspace,
        screen screenID: String = "screen_1",
        pane paneID: String,
        index: Int,
        focused: Bool
    ) -> SurfaceResource {
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: "/root",
            lifecycle: .running, agent: nil, remoteWorkspace: workspace, port: nil, url: nil
        )
        resource.remoteViews = [SurfaceRemoteView(
            tabID: "tab_\(key)", workspace: workspace, screenID: screenID, paneID: paneID,
            name: nil, index: index, focused: focused
        )]
        return resource
    }

    private func terminalKey(_ node: CloudTreeNode) -> String? {
        if case .terminal(let row) = node.kind { return row.resource.id.key }
        return nil
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

    /// Exercise the shipped CLI binary through its socket boundary. `CMUXCLI` belongs to
    /// the separate executable target and cannot be imported by the app-hosted test target;
    /// running the bundled helper keeps this assertion behavioral and compile-safe.
    private func runCLICloudTree(
        machine: [String: Any],
        resources: [[String: Any]]
    ) throws -> CloudTreeCLIResult {
        try runCLICloudCommand(arguments: ["vm", "tree"], machine: machine, resources: resources)
    }

    private func runCLICloudCommand(
        arguments: [String],
        machine: [String: Any],
        resources: [[String: Any]],
        extraResponses: [[String: Any]] = []
    ) throws -> CloudTreeCLIResult {
        let socketPath = "/tmp/cmux-cloud-tree-cli-\(UUID().uuidString.prefix(8)).sock"
        let machineID = machine["id"] as? String
        let catalogResources = resources.map { resource -> [String: Any] in
            var resource = resource
            // The socket catalog carries the owning machine separately from the
            // resource id. Fixtures can omit that redundant field when they are
            // used directly by the sidebar builder; fill it for the CLI wire
            // path so the command sees the same resources.
            if resource["machine"] == nil, let machineID {
                resource["machine"] = machineID
            }
            return resource
        }
        let catalog: [String: Any] = [
            "ok": true,
            "result": [
                "machines": [machine],
                "resources": catalogResources,
                "projections": [],
            ],
        ]
        let payloads = try ([catalog] + extraResponses).map { object in
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let responder = try UnixSocketResponder(path: socketPath, responses: payloads)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = try BundledCLITestSupport.bundledCLIURL(
            for: CloudTreeCLIBundleToken.self
        )
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CloudTreeCLIResult(
            status: process.terminationStatus,
            stdout: String(decoding: output, as: UTF8.self),
            stderr: String(decoding: error, as: UTF8.self),
            requests: responder.receivedRequests
        )
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
            "machine:brave-otter/terminals",
            "resource:brave-otter/terminal/term_1",
        ], "the group is its own row above the lone workspace — never folded into it")
        let group = try #require(tree.first { $0.id == "machine:brave-otter/workspaces" })
        #expect(group.structureTag == "workspacesGroup")
        #expect(CloudTreeRowHoverButtons.hasButtons(for: group.kind), "the group's hover + (New Workspace) stays reachable on a one-workspace machine")
        let row = try #require(tree.first { $0.id == "machine:brave-otter/ws/ws_main" })
        #expect(row.searchableTitle == "main", "the workspace row carries its own name, not a 'Workspaces / main' breadcrumb")
        #expect(!row.isMachineRow, "a workspace is a row under its machine, never a machine of its own")
    }

    @Test("Under a connected machine: Workspaces, Ports, VNC Displays, then Terminals (every terminal) as the last section")
    func workspacesPortsDisplaysThenTerminals() throws {
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
            "machine:brave-otter/ports",
            "resource:brave-otter/browser/port:3000",
            "machine:brave-otter/displays",
            "resource:brave-otter/display/display:1",
            "machine:brave-otter/terminals",
            "resource:brave-otter/terminal/term_1",
            "resource:brave-otter/terminal/term_2",
            "resource:brave-otter/terminal/term_3",
            "resource:brave-otter/terminal/term_shared",
        ], "the machine's four groups in order, Terminals last; a daemon browser in no workspace gets no group of its own")
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
        guard case .workspace(_, _, let mainCount, _, _) = try #require(byID["machine:brave-otter/ws/ws_main"]).kind,
              case .workspace(_, _, let sideCount, _, _) = try #require(byID["machine:brave-otter/ws/ws_side"]).kind else {
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
        #expect(tree.last?.id == "resource:brave-otter/terminal/term_shared", "Terminals is the machine's last section")
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

    /// Regression (https://github.com/manaflow-ai/cmux/issues/12044 follow-up): a pane
    /// holding several tabs listed every tab as a peer row, so a workspace read
    /// "3 terminals" while its layout showed one pane. A workspace's rows are its layout:
    /// one row per pane (the tab the pane shows), the pane's other tabs nested beneath it
    /// in tab order.
    @Test("A pane with several tabs is one row: the tab it shows, with its other tabs nested beneath")
    func hiddenTabsNestUnderTheirPaneRow() throws {
        let main = workspace("ws_main", "main", index: 0, focused: true)
        // One pane, three tabs; the daemon shows the middle one.
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(workspaces: [main])],
            resources: [
                tabbedTerminal("term_a", in: main, pane: "pane_1", index: 0, focused: false),
                tabbedTerminal("term_b", in: main, pane: "pane_1", index: 1, focused: true),
                tabbedTerminal("term_c", in: main, pane: "pane_1", index: 2, focused: false),
            ],
            projections: []
        )
        let tree = rows(snapshot)
        let byID = Dictionary(tree.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaceRow = try #require(byID["machine:brave-otter/ws/ws_main"])
        #expect(workspaceRow.children.compactMap(terminalKey) == ["term_b"], "one pane in the layout, one row: the tab the pane shows")
        let paneRow = try #require(workspaceRow.children.first)
        #expect(paneRow.children.compactMap(terminalKey) == ["term_a", "term_c"], "the pane's other tabs nest beneath it, in tab order")
        guard case .workspace(_, _, let count, let hiddenTabs, _) = workspaceRow.kind else {
            Issue.record("expected the workspace row"); return
        }
        #expect(count == 1, "the count is what the layout shows")
        #expect(hiddenTabs == 2, "and the row says how many tabs sit behind the shown ones")
        #expect(CloudTreeRowContentView.workspaceDetail(terminalCount: count, hiddenTabCount: hiddenTabs) == "1 terminal · 2 more tabs")
        guard case .terminal(let shownRow) = paneRow.kind else {
            Issue.record("expected the pane row"); return
        }
        #expect(shownRow.hiddenTabCount == 2, "the pane row carries the count its badge shows")
        #expect(paneRow.children.allSatisfy { child in
            if case .terminal(let row) = child.kind { return row.hiddenTabCount == 0 }
            return false
        }, "nested tab rows carry no badge of their own")
        // Every terminal keeps its one pool row, whatever pane or tab shows it.
        let pool = try #require(tree.first { $0.structureTag == "terminalsPool" })
        #expect(pool.children.compactMap(terminalKey) == ["term_a", "term_b", "term_c"])
    }

    @Test("Collapsing a pane keeps it collapsed after the pane shows a different tab")
    @MainActor
    func collapsingAPaneSurvivesSwitchingItsShownTab() throws {
        let main = workspace("ws_main", "main", index: 0, focused: true)
        func paneRow(focused: String) throws -> CloudTreeNode {
            let snapshot = SurfaceCatalogSnapshot(
                machines: [info(workspaces: [main])],
                resources: [
                    tabbedTerminal("term_a", in: main, pane: "pane_1", index: 0, focused: focused == "term_a"),
                    tabbedTerminal("term_b", in: main, pane: "pane_1", index: 1, focused: focused == "term_b"),
                    tabbedTerminal("term_c", in: main, pane: "pane_1", index: 2, focused: focused == "term_c"),
                ],
                projections: []
            )
            let workspaceRow = try #require(rows(snapshot).first { $0.id == "machine:brave-otter/ws/ws_main" })
            return try #require(workspaceRow.children.first)
        }
        let shownB = try paneRow(focused: "term_b")
        let shownC = try paneRow(focused: "term_c")
        #expect(shownB.id == shownC.id, "the pane row is the same row when a different tab is shown")
        #expect(terminalKey(shownB) == "term_b")
        #expect(terminalKey(shownC) == "term_c")
        let suite = "CloudTreePaneExpansion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudTreeExpansionStore(defaults: defaults)
        store.setExpanded(false, node: shownB)
        #expect(!store.isExpanded(shownC), "collapse is keyed by the pane, not the shown tab")
    }

    @Test("A pane row keeps its identity when a second tab appears")
    func paneIdentitySurvivesTabAppearance() throws {
        let main = workspace("ws_main", "main", index: 0, focused: true)
        func paneRow(_ resources: [SurfaceResource]) throws -> CloudTreeNode {
            let snapshot = SurfaceCatalogSnapshot(
                machines: [info(workspaces: [main])], resources: resources, projections: []
            )
            let workspaceRow = try #require(rows(snapshot).first { $0.id == "machine:brave-otter/ws/ws_main" })
            return try #require(workspaceRow.children.first)
        }
        let first = tabbedTerminal("term_a", in: main, pane: "pane_1", index: 0, focused: true)
        let second = tabbedTerminal("term_b", in: main, pane: "pane_1", index: 1, focused: false)
        let oneTab = try paneRow([first])
        let twoTabs = try paneRow([first, second])
        #expect(oneTab.id == twoTabs.id)
        #expect(oneTab.id.contains("pane:pane_1"))
    }

    @Test("Pane rows follow the layout: the screen, then the pane's position in its split tree")
    func paneRowsFollowTheLayoutOrder() throws {
        let main = workspace("ws_main", "main", index: 0, focused: true)
        func placed(_ key: String, pane: String, paneIndex: Int, index: Int = 0, focused: Bool = true) -> SurfaceResource {
            var resource = tabbedTerminal(key, in: main, pane: pane, index: index, focused: focused)
            resource.remoteViews?[0].screenIndex = 0
            resource.remoteViews?[0].paneIndex = paneIndex
            return resource
        }
        // Arrival order puts the right pane first; the layout document says left, then right.
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(workspaces: [main])],
            resources: [
                placed("term_right", pane: "pane_right", paneIndex: 1),
                placed("term_left", pane: "pane_left", paneIndex: 0),
                placed("term_right_hidden", pane: "pane_right", paneIndex: 1, index: 1, focused: false),
            ],
            projections: []
        )
        let tree = rows(snapshot)
        let byID = Dictionary(tree.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaceRow = try #require(byID["machine:brave-otter/ws/ws_main"])
        #expect(workspaceRow.children.compactMap(terminalKey) == ["term_left", "term_right"], "layout order, not arrival order")
        #expect(workspaceRow.children.last?.children.compactMap(terminalKey) == ["term_right_hidden"])
        guard case .workspace(_, _, let count, let hidden, _) = workspaceRow.kind else {
            Issue.record("expected the workspace row"); return
        }
        #expect(count == 2)
        #expect(hidden == 1)
        #expect(CloudTreeRowContentView.workspaceDetail(terminalCount: count, hiddenTabCount: hidden) == "2 terminals · 1 more tab")
        // Views that name no pane (older providers) keep the flat rows they always had.
        let legacy = SurfaceCatalogSnapshot(
            machines: [info(workspaces: [main])],
            resources: [terminal("term_1", in: [main]), terminal("term_2", in: [main])],
            projections: []
        )
        let legacyRow = try #require(rows(legacy).first { $0.id == "machine:brave-otter/ws/ws_main" })
        #expect(legacyRow.children.compactMap(terminalKey) == ["term_1", "term_2"])
        #expect(legacyRow.children.allSatisfy { $0.children.isEmpty })
    }

    @Test("A row-local tab rename preserves the pane's shown row and hidden-tab order", arguments: [false, true])
    func tabRenameKeepsSnapshotAndDeltaLayoutOrder(explicitIndices: Bool) throws {
        let main = workspace("ws_main", "main", index: 0, focused: true)
        var tabs: [[String: Any]] = [
            ["id": "tab_a", "pane_id": "pane_1", "content_kind": "terminal", "content_id": "term_a"],
            ["id": "tab_b", "pane_id": "pane_1", "content_kind": "terminal", "content_id": "term_b"],
        ]
        if explicitIndices {
            tabs[0]["index"] = 0
            tabs[1]["index"] = 1
        }
        let document: [String: Any] = [
            "cursor": ["generation": "layout-test", "revision": "1"],
            "workspaces": [["id": "ws_main", "name": "main", "index": 0, "focused": true]],
            "screens": [["id": "screen_1", "workspace_id": "ws_main"]],
            "panes": [["id": "pane_1", "screen_id": "screen_1"]],
            "tabs": tabs,
            "terminals": [
                ["id": "term_a", "tab_ids": ["tab_a"], "title": "term_a", "running": true],
                ["id": "term_b", "tab_ids": ["tab_b"], "title": "term_b", "running": true],
            ],
            "browsers": [], "agents": [],
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
        let initial = CmuxTuiSnapshotParser.resources(from: state)
        var renamedTab = tabs[1]
        renamedTab["name"] = "renamed"
        let delta: [String: Any] = [
            "kind": "delta", "previous_revision": "1", "revision": "2",
            "changes": [["kind": "upsert", "resource": "tab", "id": "tab_b", "value": renamedTab]],
        ]
        let deltaData = try JSONSerialization.data(withJSONObject: delta)
        let next = try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: deltaData,
            cursor: CloudVMCursor(generation: "layout-test", revision: 2), to: state
        ))
        let updated = try #require(CmuxTuiSnapshotParser.resources(
            from: next, matching: [SurfaceResourceID(machine: machine, kind: .terminal, key: "term_b")]
        ).first)
        let rowLocal = initial.map { $0.id == updated.id ? updated : $0 }
        func workspaceRow(_ resources: [SurfaceResource]) throws -> CloudTreeNode {
            let catalog = SurfaceCatalogSnapshot(machines: [info(workspaces: [main])], resources: resources, projections: [])
            return try #require(rows(catalog).first { $0.structureTag == "workspace" })
        }
        let before = try workspaceRow(initial)
        let after = try workspaceRow(rowLocal)
        let refreshed = try workspaceRow(CmuxTuiSnapshotParser.resources(from: next))
        #expect(before.children.count == 1)
        #expect(before.children.first?.id.contains("pane:pane_1") == true)
        #expect(after.children.map(\.id) == before.children.map(\.id))
        #expect(after.children.flatMap { $0.children }.map(\.id) == before.children.flatMap { $0.children }.map(\.id))
        #expect(refreshed.children.map(\.id) == after.children.map(\.id))
        #expect(updated.remoteViews?.first?.name == "renamed")
    }

    @Test("The CLI shows a pane's hidden tabs indented beneath the tab the pane shows")
    func cliTreeNestsHiddenTabs() throws {
        let workspace: [String: Any] = ["id": "ws_main", "name": "main", "index": 0, "focused": true]
        let machine: [String: Any] = [
            "id": machineID, "status": "running", "link_state": "connected", "has_desktop": false,
            "remote_workspaces": [workspace],
        ]
        func terminal(_ key: String, tab: String, index: Int, focused: Bool) -> [String: Any] {
            [
                "id": "\(machineID)/terminal/\(key)", "key": key, "kind": "terminal", "title": key, "lifecycle": "running",
                "remote_workspace": workspace,
                "remote_views": [[
                    "tab_id": tab, "workspace": workspace, "screen_id": "screen_1", "pane_id": "pane_1",
                    "index": index, "focused": focused,
                ] as [String: Any]],
            ]
        }
        let result = try runCLICloudTree(machine: machine, resources: [
            terminal("term_a", tab: "tab_a", index: 0, focused: false),
            terminal("term_b", tab: "tab_b", index: 1, focused: true),
        ])
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        func isPaneRow(_ line: String) -> Bool { line.hasPrefix("      ") && !line.hasPrefix("        ") }
        let shown = try #require(lines.firstIndex { isPaneRow($0) && $0.contains("term_b") }, Comment(rawValue: result.stdout))
        #expect(lines[shown].contains("(+1 hidden)"), Comment(rawValue: lines[shown]))
        #expect(lines[shown + 1].hasPrefix("        ↳ tab") && lines[shown + 1].contains("term_a"), Comment(rawValue: lines[shown + 1]))
        #expect(!lines.contains { isPaneRow($0) && $0.contains("term_a") }, "the hidden tab is not a peer row")
    }

    @Test("CLI open commands name the exact tab when one terminal occupies several")
    func cliTreeOpenCommandsIdentifyTheTab() throws {
        let workspace: [String: Any] = ["id": "ws_main", "name": "main", "index": 0, "focused": true]
        let machine: [String: Any] = [
            "id": machineID, "status": "running", "link_state": "connected", "has_desktop": false,
            "remote_workspaces": [workspace],
        ]
        let resource: [String: Any] = [
            "id": "\(machineID)/terminal/term_shared",
            "key": "term_shared",
            "kind": "terminal",
            "title": "bash",
            "lifecycle": "running",
            "remote_workspace": workspace,
            "remote_views": [
                [
                    "tab_id": "tab_a", "workspace": workspace, "screen_id": "screen_1", "pane_id": "pane_1",
                    "name": "build", "index": 0, "focused": false,
                ] as [String: Any],
                [
                    "tab_id": "tab_b", "workspace": workspace, "screen_id": "screen_1", "pane_id": "pane_1",
                    "name": "shell", "index": 1, "focused": true,
                ] as [String: Any],
            ],
        ]
        let result = try runCLICloudTree(machine: machine, resources: [resource])
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        func isPaneRow(_ line: String) -> Bool { line.hasPrefix("      ") && !line.hasPrefix("        ") }
        let shown = try #require(lines.first { isPaneRow($0) && $0.contains("term_shared") }, Comment(rawValue: result.stdout))
        let hidden = try #require(lines.first { $0.contains("↳ tab") }, Comment(rawValue: result.stdout))
        #expect(shown.contains("cmux vm open \(machineID)/ws_main/term_shared/tab_b"), Comment(rawValue: shown))
        #expect(hidden.contains("cmux vm open \(machineID)/ws_main/term_shared/tab_a"), Comment(rawValue: hidden))
        #expect(shown.contains("shell"), "the shown row uses the tab name")
        #expect(hidden.contains("build"), "the hidden row uses its own tab name")
        #expect(!shown.contains("/term_shared)"), "a tab-less command would open the focused tab for both rows")
        #expect(!hidden.contains("/term_shared)"))

        let opened = try runCLICloudCommand(
            arguments: ["vm", "open", "\(machineID)/ws_main/term_shared/tab_a", "--json"],
            machine: machine,
            resources: [resource],
            extraResponses: [[
                "ok": true,
                "result": [
                    "surface_id": "surface-1",
                    "workspace_id": "workspace-1",
                    "reused": false,
                ],
            ]]
        )
        #expect(opened.status == 0, Comment(rawValue: opened.stderr))
        let project = try #require(opened.requests.first { $0.contains("surface.project") }, Comment(rawValue: opened.requests.joined(separator: "\n")))
        #expect(project.contains("\"remote_tab_id\":\"tab_a\""), Comment(rawValue: project))
        #expect(!project.contains("\"remote_tab_id\":\"tab_b\""), Comment(rawValue: project))
    }

    @Test("A terminal that left a workspace's layout leaves its folder; Terminals still lists it, greyed as detached")
    func aTerminalOutOfTheLayoutLeavesTheWorkspaceFolder() throws {
        let main = workspace("ws_main", "main", index: 0, focused: true)
        let side = workspace("ws_side", "side", index: 1)
        // Its tab in main was closed; the process keeps running on the machine.
        let detached = terminal("term_bg", title: "cargo watch", in: [])
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(workspaces: [main, side])],
            resources: [terminal("term_1", in: [main]), detached, terminal("term_2", in: [side])],
            projections: []
        )
        let tree = rows(snapshot)
        #expect(tree.map(\.id) == [
            "machine:brave-otter",
            "machine:brave-otter/workspaces",
            "machine:brave-otter/ws/ws_main",
            "machine:brave-otter/ws/ws_main/resource:brave-otter/terminal/term_1",
            "machine:brave-otter/ws/ws_side",
            "machine:brave-otter/ws/ws_side/resource:brave-otter/terminal/term_2",
            "machine:brave-otter/terminals",
            "resource:brave-otter/terminal/term_1",
            "resource:brave-otter/terminal/term_bg",
            "resource:brave-otter/terminal/term_2",
        ], "no row for it under any workspace; one row for it in Terminals, like every other terminal")
        let byID = Dictionary(tree.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard case .terminal(let poolRow) = try #require(byID["resource:brave-otter/terminal/term_bg"]).kind,
              case .terminal(let viewedPoolRow) = try #require(byID["resource:brave-otter/terminal/term_1"]).kind,
              case .terminal(let layoutRow) = try #require(byID["machine:brave-otter/ws/ws_main/resource:brave-otter/terminal/term_1"]).kind else {
            Issue.record("expected the terminal rows"); return
        }
        #expect(poolRow.isDetached, "greyed, marked detached")
        #expect(poolRow.viewBadge == 0)
        #expect(!viewedPoolRow.isDetached && !layoutRow.isDetached)
        #expect(CloudTreeRowHoverButtons.hasButtons(for: .terminal(poolRow)), "its hover × (Kill Terminal…) stays")
        #expect(byID["resource:brave-otter/terminal/term_bg"]?.isDragSource == true, "a click or drag re-attaches it in a pane")
        // The workspace is its layout: count, open/drag group, and `vm workspace open` agree.
        guard case .workspace(_, _, let count, _, _) = try #require(byID["machine:brave-otter/ws/ws_main"]).kind else {
            Issue.record("expected the workspace row"); return
        }
        #expect(count == 1)
        let layoutOnly = [SurfaceResourceID(machine: machine, kind: .terminal, key: "term_1")]
        #expect(byID["machine:brave-otter/ws/ws_main"]?.dragGroup?.resources == layoutOnly)
        guard case .found(_, let members) = CloudTreeNodeBuilder.lookupRemoteWorkspace("main", on: machine, snapshot: snapshot) else {
            Issue.record("expected main by name"); return
        }
        #expect(members.ids == layoutOnly)
    }

    @Test("VNC Displays lists one row per screen, each telling its screen apart")
    func displaysAreOnePerScreen() throws {
        let main = workspace("ws_main", "main", index: 0, focused: true)
        let first = display(in: [])
        let second = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .display, key: "display:2"), title: "Desktop", detail: nil,
            lifecycle: .running, agent: nil, remoteWorkspace: nil, port: 6901, url: nil
        )
        let snapshot = SurfaceCatalogSnapshot(machines: [info(workspaces: [main], hasDesktop: true)], resources: [first, second], projections: [])
        let tree = rows(snapshot)
        #expect(tree.map(\.id).suffix(5) == [
            "machine:brave-otter/displays",
            "resource:brave-otter/display/display:1",
            "resource:brave-otter/display/display:2",
            "machine:brave-otter/terminals",
            "machine:brave-otter/terminals/placeholder",
        ], "the screens sit above the Terminals section")
        guard case .displaysPool(_, let count) = try #require(tree.first { $0.id == "machine:brave-otter/displays" }).kind else {
            Issue.record("expected the VNC Displays group"); return
        }
        #expect(count == 2)
        #expect(CloudTreeRowContentView.text(for: first) == "noVNC · :1")
        #expect(CloudTreeRowContentView.text(for: second) == "noVNC · :2")
        #expect(CloudTreeRowContentView.screenLabel(displayKey: "display:2") == ":2")
        #expect(CloudTreeRowContentView.screenLabel(displayKey: "desktop") == nil)
        #expect(CloudTreeRowContentView.screenLabel(displayKey: "display:") == nil)
    }

    @Test("The CLI keeps detached terminals in the final Terminals section and mirrors the sidebar order")
    func cliTreeUsesTheFourGroupOrder() throws {
        let workspace: [String: Any] = [
            "id": "ws_main",
            "name": "main",
            "index": 0,
            "focused": true,
        ]
        let machine: [String: Any] = [
            "id": machineID,
            "status": "running",
            "link_state": "connected",
            "has_desktop": true,
            "remote_workspaces": [workspace],
        ]
        let visible: [String: Any] = [
            "id": "\(machineID)/terminal/term_visible",
            "key": "term_visible",
            "kind": "terminal",
            "title": "bash",
            "lifecycle": "running",
            "remote_workspace": workspace,
            "remote_views": [["workspace": workspace]],
        ]
        let detached: [String: Any] = [
            "id": "\(machineID)/terminal/term_detached",
            "key": "term_detached",
            "kind": "terminal",
            "title": "worker",
            "lifecycle": "running",
            "remote_workspace": workspace,
            "remote_views": [[String: Any]](),
        ]
        let display: [String: Any] = [
            "id": "\(machineID)/display/display:1",
            "key": "display:1",
            "kind": "display",
            "title": "Desktop",
            "detail": "noVNC",
            "lifecycle": "running",
        ]
        let port: [String: Any] = [
            "id": "\(machineID)/browser/port:3000",
            "key": "port:3000",
            "kind": "browser",
            "port": 3000,
            "detail": "http",
            "remote_views": [[String: Any]](),
        ]

        let result = try runCLICloudTree(
            machine: machine,
            resources: [visible, detached, display, port]
        )
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(
            result.requests.contains { $0.contains("surface.catalog") },
            Comment(rawValue: result.requests.joined(separator: "\n"))
        )
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        let workspaces = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "workspaces/" })
        let ports = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "ports/" })
        let displays = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "VNC Displays/" })
        let terminals = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "terminals/" })

        #expect(workspaces < ports)
        #expect(ports < displays)
        #expect(displays < terminals)
        #expect(!lines[..<terminals].contains { $0.contains("term_detached") }, "a zero-view terminal is not a detached workspace child")
        #expect(lines[terminals...].contains { $0.contains("term_detached") }, "the final Terminals section lists every machine-owned terminal")
    }

    @Test("CLI keeps machine-owned terminals visible while a cloud link is unavailable")
    func cliTreeKeepsTerminalsWhenLinkUnavailable() throws {
        let machine: [String: Any] = [
            "id": machineID,
            "status": "paused",
            "link_state": "asleep",
            "remote_workspaces": [],
        ]
        let terminal: [String: Any] = [
            "id": "\(machineID)/terminal/term_sleeping",
            "key": "term_sleeping",
            "kind": "terminal",
            "title": "worker",
            "lifecycle": "running",
            "remote_views": [[String: Any]](),
        ]

        let result = try runCLICloudTree(machine: machine, resources: [terminal])
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        let terminals = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "terminals/" })

        #expect(lines[terminals...].contains { $0.contains("term_sleeping") })
    }

    @Test("An exited terminal with no resolved views is not marked detached")
    func exitedZeroViewTerminalIsNotDetached() throws {
        let exited = terminal("term_exited", lifecycle: .exited, in: [])
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(workspaces: [])],
            resources: [exited],
            projections: []
        )

        let tree = rows(snapshot)
        guard case .terminal(let row) = try #require(
            tree.first { $0.id == "resource:brave-otter/terminal/term_exited" }
        ).kind else {
            Issue.record("expected the exited terminal row")
            return
        }
        #expect(!row.isDetached, "an exited record with unresolved views stays an ordinary exited row")
    }

    @Test("Sidebar keeps machine-owned terminals visible for unavailable cloud links")
    func sidebarKeepsTerminalsWhenLinkUnavailable() throws {
        let terminal = terminal("term_sleeping", in: [])
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(workspaces: [], linkState: .asleep)],
            resources: [terminal],
            projections: []
        )

        let tree = rows(snapshot)
        #expect(tree.contains { $0.id == "machine:brave-otter/terminals" })
        #expect(tree.contains { $0.id == "resource:brave-otter/terminal/term_sleeping" })
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
