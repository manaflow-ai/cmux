import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

typealias CMUXCLI = CmuxTuiRemoteRouting

/// The cmux-tui provider's pure parts: snapshot → resources, the argv it hands the
/// client, the URLs it opens, and the client identity paths it shares with the CLI.
@Suite struct CmuxTuiSurfaceProviderTests {
    static let machine = SurfaceMachineID.cloud("vivid-newt")

    static let sessionSnapshot: [String: Any] = [
        "workspaces": [
            ["id": "ws_main", "name": "main", "focused": true],
            ["id": "ws_api", "name": "api", "focused": false],
        ],
        "screens": [
            ["id": "screen_1", "workspace_id": "ws_main"],
            ["id": "screen_2", "workspace_id": "ws_api"],
        ],
        "panes": [
            ["id": "pane_1", "screen_id": "screen_1"],
            ["id": "pane_2", "screen_id": "screen_2"],
        ],
        "tabs": [
            ["id": "tab_1", "pane_id": "pane_1", "content_kind": "terminal", "content_id": "term_build"],
            ["id": "tab_2", "pane_id": "pane_2", "content_kind": "terminal", "content_id": "term_shell"],
            ["id": "tab_3", "pane_id": "pane_1", "content_kind": "browser", "content_id": "browser_1"],
            ["id": "tab_4", "pane_id": "pane_2", "content_kind": "terminal", "content_id": "term_build"],
        ],
        "terminals": [
            ["id": "term_build", "tab_id": "tab_1", "tab_ids": ["tab_1", "tab_4"], "title": "cargo test", "cwd": "/root/work/app", "lifecycle": "running", "running": true],
            ["id": "term_shell", "tab_id": "tab_2", "tab_ids": ["tab_2"], "title": "", "lifecycle": "exited", "running": false],
            ["id": "term_detached", "tab_id": "tab_missing", "tab_ids": [], "title": "detached", "running": true],
        ],
        "browsers": [],
        "agents": [
            ["id": "agent_1", "terminal_id": "term_build", "state": "working", "source": "claude"],
        ],
    ]

    @Test func snapshotBecomesTerminalResourcesWithEveryView() throws {
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: Self.sessionSnapshot, machine: Self.machine)
        #expect(resources.map { $0.id.key } == ["term_build", "term_shell", "term_detached"], "workspace order, zero-view terminals trail")
        #expect(resources.allSatisfy { $0.kind == .terminal && $0.machine == Self.machine })

        // A terminal with two tabs carries both views; `remoteWorkspace` stays the first.
        let build = try #require(resources.first { $0.id.key == "term_build" })
        #expect(build.title == "cargo test")
        #expect(build.detail == "/root/work/app")
        #expect(build.lifecycle == .running)
        #expect(build.agent == SurfaceAgentBadge(state: "working", source: "claude"))
        #expect(build.remoteWorkspace == SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true))
        #expect(build.remoteViews?.map(\.tabID) == ["tab_1", "tab_4"])
        #expect(build.remoteWorkspaces.map(\.id) == ["ws_main", "ws_api"])
        #expect(build.remoteViewCount == 2)

        // An untitled terminal stays untitled (the row shows a localized fallback, never the raw id).
        let shell = try #require(resources.first { $0.id.key == "term_shell" })
        #expect(shell.title == "")
        #expect(shell.lifecycle == .exited)
        #expect(shell.agent == nil)
        #expect(shell.remoteWorkspace?.id == "ws_api")
        #expect(shell.remoteViews?.count == 1)

        // A terminal whose tab chain does not resolve keeps zero views: it is alive in the
        // machine's pool, in no workspace. No lifecycle key → `running` decides.
        let detached = try #require(resources.first { $0.id.key == "term_detached" })
        #expect(detached.remoteWorkspace == nil)
        #expect(detached.remoteViews == [])
        #expect(detached.remoteWorkspaces.isEmpty)
        #expect(detached.lifecycle == .running)
    }

    @Test func userTabNameStaysOnTheIndividualRemoteView() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["tabs"] = [
            ["id": "tab_1", "pane_id": "pane_1", "name": "build loop", "content_kind": "terminal", "content_id": "term_build"],
            ["id": "tab_2", "pane_id": "pane_2", "name": "", "content_kind": "terminal", "content_id": "term_shell"],
            ["id": "tab_3", "pane_id": "pane_1", "content_kind": "browser", "content_id": "browser_1"],
            ["id": "tab_4", "pane_id": "pane_2", "content_kind": "terminal", "content_id": "term_build"],
        ]
        snapshot["terminals"] = [
            ["id": "term_build", "tab_id": "tab_1", "tab_ids": ["tab_1", "tab_4"], "title": "cargo test", "cwd": "/root/work/app", "lifecycle": "running", "running": true],
            ["id": "term_shell", "tab_id": "tab_2", "tab_ids": ["tab_2"], "title": "bash", "lifecycle": "running", "running": true],
        ]
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: snapshot, machine: Self.machine)

        // `tab rename` (the tree's Rename…, any TUI client) sets the tab's `name`,
        // which the daemon persists and broadcasts for that view only.
        let build = try #require(resources.first { $0.id.key == "term_build" })
        #expect(build.title == "cargo test")
        #expect(build.remoteViews?.first?.name == "build loop")
        #expect(build.remoteViews?.last?.name == nil)

        // An empty or absent name keeps the PTY title.
        let shell = try #require(resources.first { $0.id.key == "term_shell" })
        #expect(shell.title == "bash")
        #expect(CmuxTuiSnapshotParser.tabNames(fromSnapshot: snapshot) == ["tab_1": "build loop"])
    }

    @Test func terminalViewsComeFromReverseTabContentEdges() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["terminals"] = [
            ["id": "term_build", "tab_id": "tab_1", "title": "cargo test", "lifecycle": "running"],
            ["id": "term_shell", "tab_id": "tab_2", "title": "shell", "lifecycle": "running"],
        ]
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: snapshot, machine: Self.machine)
        let build = try #require(resources.first { $0.id.key == "term_build" })
        #expect(build.remoteViews?.map(\.tabID) == ["tab_1", "tab_4"])

        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        let targeted = try #require(CmuxTuiSnapshotParser.resources(
            from: state,
            matching: [SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_build")]
        ).first)
        #expect(targeted.remoteViews?.map(\.tabID) == ["tab_1", "tab_4"])

        // An older daemon can omit a tab row while retaining the terminal's
        // legacy reference. It remains safe only when the referenced row still
        // exists and identifies this terminal.
        var legacy = snapshot
        legacy["tabs"] = (snapshot["tabs"] as! [[String: Any]]).filter { $0["id"] as? String != "tab_4" }
        let legacyResources = CmuxTuiSnapshotParser.terminals(fromSnapshot: legacy, machine: Self.machine)
        let legacyBuild = try #require(legacyResources.first { $0.id.key == "term_build" })
        #expect(legacyBuild.remoteViews?.map(\.tabID) == ["tab_1"])
    }

    @Test func vmOpenWorkspaceSelectorsPreferIdsAndRejectAmbiguousNames() {
        let machine: [String: Any] = [
            "id": "vivid-newt",
            "remote_workspaces": [
                ["id": "ws-id", "name": "other"],
                // A mutable name can equal another workspace's id. The id wins.
                ["id": "ws-other", "name": "ws-id"],
                ["id": "ws-a", "name": "same"],
                ["id": "ws-b", "name": "same"],
            ],
        ]

        #expect(CMUXCLI.resolveVMRemoteWorkspaceSelector("ws-id", in: machine) == .resolved("ws-id"))
        #expect(CMUXCLI.resolveVMRemoteWorkspaceSelector("other", in: machine) == .resolved("ws-id"))
        #expect(CMUXCLI.resolveVMRemoteWorkspaceSelector("same", in: machine) == .ambiguous(["ws-a", "ws-b"]))
        #expect(CMUXCLI.resolveVMRemoteWorkspaceSelector("missing", in: machine) == .notFound)
        #expect(CMUXCLI.resolveVMRemoteWorkspaceSelector("ws-id", in: ["id": "vivid-newt"]) == .unavailable)
    }

    @Test func vmOpenWorkspaceUsesTheSelectedTabView() {
        let resource: [String: Any] = [
            "id": "vivid-newt/terminal/term_build",
            "remote_views": [
                [
                    "tab_id": "tab_main",
                    "workspace": ["id": "ws_main", "name": "main"],
                    "focused": false,
                ],
                [
                    "tab_id": "tab_api",
                    "workspace": ["id": "ws_api", "name": "api"],
                    "focused": true,
                ],
            ],
        ]

        #expect(CMUXCLI.vmRemoteView(in: resource, workspaceID: "ws_api")?["tab_id"] as? String == "tab_api")
        #expect(CMUXCLI.vmRemoteView(in: resource, workspaceID: "ws_missing") == nil)

        var duplicate = resource
        duplicate["remote_views"] = [
            [
                "tab_id": "tab_a",
                "workspace": ["id": "ws_main", "name": "main"],
                "focused": false,
            ],
            [
                "tab_id": "tab_b",
                "workspace": ["id": "ws_main", "name": "main"],
                "focused": true,
            ],
        ]
        #expect(CMUXCLI.vmRemoteView(in: duplicate, workspaceID: "ws_main")?["tab_id"] as? String == "tab_b")

        duplicate["remote_views"] = [
            ["tab_id": "tab_a", "workspace": ["id": "ws_main", "name": "main"], "focused": false],
            ["tab_id": "tab_b", "workspace": ["id": "ws_main", "name": "main"], "focused": false],
        ]
        #expect(CMUXCLI.vmRemoteView(in: duplicate, workspaceID: "ws_main") == nil)
    }

    @Test func vmOpenTerminalResolvesAnExactTabOrFailsClosed() {
        let resource: [String: Any] = [
            "id": "vivid-newt/terminal/term_build",
            "machine": "vivid-newt",
            "kind": "terminal",
            "key": "term_build",
            "remote_views": [
                [
                    "tab_id": "tab_main",
                    "workspace": ["id": "ws_main", "name": "main"],
                    "focused": false,
                ],
                [
                    "tab_id": "tab_api",
                    "workspace": ["id": "ws_api", "name": "api"],
                    "focused": true,
                ],
            ],
        ]
        let catalog: [String: Any] = ["resources": [resource]]
        #expect(CMUXCLI.resolveVMRemoteTerminalPlacement("term_build", machine: "vivid-newt", workspaceID: "ws_api", in: catalog) == .resolved(terminalID: "term_build", tabID: "tab_api"))
        #expect(CMUXCLI.resolveVMRemoteTerminalPlacement("term_build", machine: "vivid-newt", workspaceID: "ws_missing", in: catalog) == .notFound)

        var inconsistent = resource
        inconsistent["key"] = "stale-key"
        #expect(CMUXCLI.resolveVMRemoteTerminalPlacement("vivid-newt/terminal/term_build", machine: "vivid-newt", workspaceID: "ws_api", in: ["resources": [inconsistent]]) == .resolved(terminalID: "term_build", tabID: "tab_api"))

        // A catalog key must be a key, never a complete resource id. A malformed
        // explicit key must fall back to the canonical id, or fail closed when no
        // canonical id exists.
        var fullIDKey = resource
        fullIDKey["key"] = "vivid-newt/terminal/term_build"
        #expect(CMUXCLI.vmTerminalID(in: fullIDKey, machine: "vivid-newt") == "term_build")
        #expect(CMUXCLI.vmTerminalID(in: ["key": "vivid-newt/terminal/term_build"], machine: "vivid-newt") == nil)

        var duplicate = resource
        duplicate["remote_views"] = [
            ["tab_id": "tab_a", "workspace": ["id": "ws_main"], "focused": false],
            ["tab_id": "tab_b", "workspace": ["id": "ws_main"], "focused": false],
        ]
        #expect(CMUXCLI.resolveVMRemoteTerminalPlacement("term_build", machine: "vivid-newt", workspaceID: "ws_main", in: ["resources": [duplicate]]) == .ambiguous)

        #expect(CMUXCLI.resolveVMRemoteTerminalPlacement("term_build", machine: "vivid-newt", workspaceID: "ws_main", in: ["resources": [["kind": "terminal", "key": "term_build", "remote_views": NSNull()]]]) == .unavailable)

        let legacy = [
            "id": "vivid-newt/terminal/term_legacy",
            "key": "term_legacy",
            "remote_workspace": ["id": "ws_main", "name": "main"],
        ] as [String: Any]
        if case .legacy = CMUXCLI.resolveVMRemoteView(in: legacy, workspaceID: "ws_main") {
            // Whole-workspace opens may use the legacy terminal/workspace edge.
        } else {
            Issue.record("legacy workspace resources must remain openable as a group")
        }
        #expect(CMUXCLI.resolveVMRemoteTerminalPlacement(
            "term_legacy",
            machine: "vivid-newt",
            workspaceID: "ws_main",
            in: ["resources": [legacy]]
        ) == .unavailable, "an exact terminal selector still requires a tab id")
    }

    @Test func vmOpenWorkspaceSkipsAmbiguousAndExitedTerminalsWhenSafeCandidateExists() {
        let resources: [[String: Any]] = [
            [
                "id": "vivid-newt/terminal/term_ambiguous",
                "machine": "vivid-newt",
                "kind": "terminal",
                "key": "term_ambiguous",
                "lifecycle": "running",
                "remote_views": [
                    ["tab_id": "tab_a", "workspace": ["id": "ws_main"], "focused": false],
                    ["tab_id": "tab_b", "workspace": ["id": "ws_main"], "focused": false],
                ],
            ],
            [
                // An exited row must not block opening the workspace, even when its
                // stale placement is ambiguous.
                "id": "vivid-newt/terminal/term_exited",
                "machine": "vivid-newt",
                "kind": "terminal",
                "key": "term_exited",
                "lifecycle": "exited",
                "remote_views": [
                    ["tab_id": "tab_c", "workspace": ["id": "ws_main"], "focused": false],
                    ["tab_id": "tab_d", "workspace": ["id": "ws_main"], "focused": false],
                ],
            ],
            [
                "id": "vivid-newt/terminal/term_safe",
                "machine": "vivid-newt",
                "kind": "terminal",
                "key": "term_safe",
                "lifecycle": "running",
                "remote_views": [
                    ["tab_id": "tab_safe", "workspace": ["id": "ws_main"], "focused": true],
                ],
            ],
        ]

        #expect(CMUXCLI.resolveVMRemoteWorkspaceTerminal(
            resources,
            machine: "vivid-newt",
            workspaceID: "ws_main"
        ) == .resolved(terminalID: "term_safe", tabID: "tab_safe"))
    }

    @Test func cloudRenameWriteThroughTargetsAndNames() throws {
        // The persisted binding wins over projections.
        let bound = CloudWorkspaceRenameService().remoteTarget(
            binding: WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_main"),
            projectedResources: []
        )
        #expect(bound?.machine == .cloud("vivid-newt"))
        #expect(bound?.remoteWorkspaceID == "ws_main")

        // Without a binding, projections decide only when every view agrees…
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: Self.sessionSnapshot, machine: Self.machine)
        let shell = try #require(resources.first { $0.id.key == "term_shell" })
        #expect(CloudWorkspaceRenameService().remoteTarget(binding: nil, projectedResources: [shell])?.remoteWorkspaceID == "ws_api")

        // …a terminal viewed in two remote workspaces, or no panes at all, refuses to guess.
        let build = try #require(resources.first { $0.id.key == "term_build" })
        #expect(CloudWorkspaceRenameService().remoteTarget(binding: nil, projectedResources: [build])?.remoteWorkspaceID == nil)
        #expect(CloudWorkspaceRenameService().remoteTarget(binding: nil, projectedResources: [])?.remoteWorkspaceID == nil)

        // Legacy projection fallback drops the generated prefix; a bound workspace keeps
        // an intentional prefix as part of the user's exact title.
        #expect(CloudWorkspaceRenameService().remoteName(fromLocalTitle: "vivid-newt: api", machine: Self.machine) == "api")
        #expect(CloudWorkspaceRenameService().remoteName(fromLocalTitle: "vivid-newt: api", machine: Self.machine, stripGeneratedPrefix: false) == "vivid-newt: api")
        #expect(CloudWorkspaceRenameService().remoteName(fromLocalTitle: "api work", machine: Self.machine) == "api work")
        #expect(CloudWorkspaceRenameService().remoteName(fromLocalTitle: "   ", machine: Self.machine) == nil)
    }

    @Test func cloudRenameRecognizesOnlyTheActualGeneratedWorkspaceTitle() {
        #expect(
            CloudWorkspaceRenameService().isGeneratedPrefixedTitle(
                "vivid-newt: api",
                machine: Self.machine,
                remoteWorkspaceName: "api"
            )
        )
        #expect(
            !CloudWorkspaceRenameService().isGeneratedPrefixedTitle(
                "vivid-newt: api",
                machine: Self.machine,
                remoteWorkspaceName: "other"
            )
        )
        // A user-entered title with the same prefix is still exact when it does
        // not match the name that generated the previous title.
        #expect(
            !CloudWorkspaceRenameService().isGeneratedPrefixedTitle(
                "vivid-newt: api",
                machine: Self.machine,
                remoteWorkspaceName: "api work"
            )
        )
    }

    @Test func cloudTerminalRenameRejectsMismatchedLegacyWorkspaceFallback() throws {
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: Self.sessionSnapshot, machine: Self.machine)
        let shell = try #require(resources.first { $0.id.key == "term_shell" })
        let workspaceID = UUID()

        let exact = SurfaceProjection(
            resource: shell.id,
            workspaceID: workspaceID,
            panelID: UUID(),
            remoteWorkspaceID: "ws_api",
            remoteTabID: "tab_2"
        )
        #expect(CloudWorkspaceRenameService().remoteTabID(for: exact, resource: shell) == "tab_2")

        let matchingLegacy = SurfaceProjection(
            resource: shell.id,
            workspaceID: workspaceID,
            panelID: UUID(),
            remoteWorkspaceID: "ws_api"
        )
        #expect(CloudWorkspaceRenameService().remoteTabID(for: matchingLegacy, resource: shell) == "tab_2")

        let mismatchedLegacy = SurfaceProjection(
            resource: shell.id,
            workspaceID: workspaceID,
            panelID: UUID(),
            remoteWorkspaceID: "ws_main"
        )
        #expect(CloudWorkspaceRenameService().remoteTabID(for: mismatchedLegacy, resource: shell) == nil)

        let unscopedLegacy = SurfaceProjection(
            resource: shell.id,
            workspaceID: workspaceID,
            panelID: UUID()
        )
        #expect(CloudWorkspaceRenameService().remoteTabID(for: unscopedLegacy, resource: shell) == "tab_2")

        let build = try #require(resources.first { $0.id.key == "term_build" })
        let ambiguous = SurfaceProjection(
            resource: build.id,
            workspaceID: workspaceID,
            panelID: UUID(),
            remoteWorkspaceID: "ws_main"
        )
        #expect(CloudWorkspaceRenameService().remoteTabID(for: ambiguous, resource: build) == nil)
    }

    @Test func inferredWorkspaceBindingRequiresOneCloudIdentity() throws {
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: Self.sessionSnapshot, machine: Self.machine)
        let shell = try #require(resources.first { $0.id.key == "term_shell" })
        let build = try #require(resources.first { $0.id.key == "term_build" })
        let workspaceID = UUID()

        let exact = SurfaceProjection(
            resource: shell.id,
            workspaceID: workspaceID,
            panelID: UUID(),
            remoteWorkspaceID: "ws_api",
            remoteTabID: "tab_2"
        )
        #expect(
            CloudWorkspaceRenameService().inferredRemoteWorkspaceTarget(
                projections: [exact],
                resources: resources
            )?.remoteWorkspaceID == "ws_api"
        )

        // A legacy projection can infer its workspace only when the resource has one view.
        let legacy = SurfaceProjection(
            resource: shell.id,
            workspaceID: workspaceID,
            panelID: UUID()
        )
        #expect(
            CloudWorkspaceRenameService().inferredRemoteWorkspaceTarget(
                projections: [legacy],
                resources: resources
            )?.remoteWorkspaceID == "ws_api"
        )

        // A mixed local workspace and a terminal shown in two remote workspaces are both
        // intentionally unbound, because neither has one honest workspace owner.
        let local = SurfaceResource(
            id: SurfaceResourceID(machine: .local, kind: .terminal, key: "local"),
            title: "local",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: nil,
            port: nil,
            url: nil
        )
        let localProjection = SurfaceProjection(
            resource: local.id,
            workspaceID: workspaceID,
            panelID: UUID()
        )
        #expect(
            CloudWorkspaceRenameService().inferredRemoteWorkspaceTarget(
                projections: [exact, localProjection],
                resources: resources + [local]
            ) == nil
        )
        let multiView = SurfaceProjection(
            resource: build.id,
            workspaceID: workspaceID,
            panelID: UUID(),
            remoteWorkspaceID: "ws_main",
            remoteTabID: "tab_1"
        )
        #expect(
            CloudWorkspaceRenameService().inferredRemoteWorkspaceTarget(
                projections: [exact, multiView],
                resources: resources
            ) == nil
        )
    }

    @Test func cloudVMBindingSnapshotCarriesTheRemoteWorkspace() throws {
        // Legacy snapshots (no remote id) still decode and restore machine-only bindings.
        let legacy = try JSONDecoder().decode(SessionCloudVMBindingSnapshot.self, from: Data(#"{"vmID":"vivid-newt","isBase":false}"#.utf8))
        #expect(Workspace.restoredCloudVMBinding(from: legacy) == WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false))
        // New snapshots round-trip the remote workspace id through Codable and restore.
        let bound = SessionCloudVMBindingSnapshot(vmID: "vivid-newt", isBase: true, remoteWorkspaceID: "ws_main")
        let decoded = try JSONDecoder().decode(SessionCloudVMBindingSnapshot.self, from: JSONEncoder().encode(bound))
        #expect(Workspace.restoredCloudVMBinding(from: decoded) == WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: true, remoteWorkspaceID: "ws_main"))
    }

    @Test func snapshotBrowsersJoinTheirWorkspaces() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["browsers"] = [
            ["id": "browser_1", "tab_id": "tab_3", "url": "http://localhost:3000/app", "title": "Vite", "status": "live"],
            ["id": "browser_2", "tab_id": "tab_missing", "url": "https://example.com", "title": "Docs", "status": "live"],
        ]
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: snapshot, machine: Self.machine)

        // A daemon browser is workspace tab content like a terminal: it carries the
        // view of the tab that shows it and projects through its localhost port.
        let browser = try #require(resources.first { $0.id.key == "browser_1" })
        #expect(browser.kind == .browser)
        #expect(browser.title == "Vite")
        #expect(browser.url == "http://localhost:3000/app")
        #expect(browser.port == 3000)
        #expect(browser.remoteWorkspace?.id == "ws_main")
        #expect(browser.remoteViews?.map(\.tabID) == ["tab_3"])

        // An unresolvable tab chain leaves the browser in the pool; a non-localhost
        // URL has no port to project through.
        let detached = try #require(resources.first { $0.id.key == "browser_2" })
        #expect(detached.remoteViews == [])
        #expect(detached.remoteWorkspace == nil)
        #expect(detached.port == nil)
    }

    @Test func localhostPortParsesOnlyMachineLocalURLs() {
        #expect(CmuxTuiSnapshotParser.localhostPort(fromURL: "http://localhost:5173/x?y=1") == 5173)
        #expect(CmuxTuiSnapshotParser.localhostPort(fromURL: "http://127.0.0.1:8080") == 8080)
        #expect(CmuxTuiSnapshotParser.localhostPort(fromURL: "http://localhost/") == 80)
        #expect(CmuxTuiSnapshotParser.localhostPort(fromURL: "https://cmux.com") == nil)
        #expect(CmuxTuiSnapshotParser.localhostPort(fromURL: "not a url") == nil)
    }

    @Test func privateBrowserURLPreservesTheVisibleURL() throws {
        #expect(
            CmuxTuiSurfaceProvider.privateBrowserURL(
                "http://localhost:5173/docs/page?q=one#result",
                privateAddress: "10.16.4.9"
            ) == "http://10.16.4.9:5173/docs/page?q=one#result"
        )
        #expect(
            CmuxTuiSurfaceProvider.privateBrowserURL(
                "https://127.0.0.1:8443/path",
                privateAddress: "fd98:deb9:4c94::8"
            ) == "https://[fd98:deb9:4c94::8]:8443/path"
        )
        #expect(CmuxTuiSurfaceProvider.privateBrowserURL("https://cmux.com", privateAddress: "10.0.0.2") == nil)
        #expect(
            CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: "10.16.4.9")
                == "http://10.16.4.9:6901/vnc.html?path=websockify&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"
        )
    }

    @Test func snapshotListsEveryWorkspaceIncludingEmptyOnes() {
        let workspaces = CmuxTuiSnapshotParser.workspaces(fromSnapshot: Self.sessionSnapshot)
        #expect(workspaces == [
            SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true),
            SurfaceRemoteWorkspace(id: "ws_api", name: "api", index: 1, focused: false),
        ])
        #expect(CmuxTuiSnapshotParser.workspaces(fromSnapshot: [:]).isEmpty)
    }

    @Test func zeroViewTerminalGetsAStableFocusedProjectionTarget() throws {
        let target = try #require(
            CmuxTuiSnapshotParser.terminalProjectionTarget(from: Self.sessionSnapshot)
        )
        #expect(target == CloudTuiTerminalProjectionTarget(
            workspaceID: "ws_main",
            screenID: "screen_1",
            paneID: "pane_1",
            index: 2
        ))
    }

    @Test func projectionTargetSkipsAnEmptyFocusedWorkspace() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["screens"] = [
            ["id": "screen_api", "workspace_id": "ws_api", "focused": true],
        ]
        snapshot["panes"] = [
            ["id": "pane_api", "screen_id": "screen_api", "focused": true],
        ]
        snapshot["tabs"] = []
        let target = try #require(
            CmuxTuiSnapshotParser.terminalProjectionTarget(from: snapshot)
        )
        #expect(target.workspaceID == "ws_api")
        #expect(target.screenID == "screen_api")
        #expect(target.paneID == "pane_api")
        #expect(target.index == 0)
    }

    @Test func explicitLayoutIndexesWinOverSnapshotArrayOrder() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["workspaces"] = [
            ["id": "ws_api", "name": "api", "index": 1, "focused": false],
            ["id": "ws_main", "name": "main", "index": 0, "focused": false],
        ]
        snapshot["screens"] = [
            ["id": "screen_main_late", "workspace_id": "ws_main", "index": 2, "focused": false],
            ["id": "screen_api", "workspace_id": "ws_api", "index": 1, "focused": false],
            ["id": "screen_main", "workspace_id": "ws_main", "index": 0, "focused": false],
        ]
        snapshot["panes"] = [
            ["id": "pane_main_late", "screen_id": "screen_main_late", "focused": false],
            ["id": "pane_api", "screen_id": "screen_api", "focused": false],
            ["id": "pane_main", "screen_id": "screen_main", "focused": false],
        ]
        snapshot["tabs"] = []
        snapshot["terminals"] = []
        snapshot["browsers"] = []
        snapshot["agents"] = []

        // Index values are semantic layout coordinates. The JSON array is a
        // transport detail and is intentionally out of order in this fixture.
        let workspaces = CmuxTuiSnapshotParser.workspaces(fromSnapshot: snapshot)
        #expect(workspaces.map(\.id) == ["ws_main", "ws_api"])

        let target = try #require(CmuxTuiSnapshotParser.terminalProjectionTarget(from: snapshot))
        #expect(target.workspaceID == "ws_main")
        #expect(target.screenID == "screen_main")
        #expect(target.paneID == "pane_main")

        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        #expect(state.lookupIndex.screenIDs(workspaceID: "ws_main") == ["screen_main", "screen_main_late"])
    }

    @Test func terminalProjectionArgvUsesTheRemoteDestination() {
        let target = CloudTuiTerminalProjectionTarget(
            workspaceID: "ws_main", screenID: "screen_1", paneID: "pane_1", index: 2
        )
        #expect(
            CloudTuiCommandLine.projectTerminalArguments(
                socketPath: "/k.sock", terminalID: "term_detached", target: target
            ) == [
                "--socket", "/k.sock", "--json", "terminal", "term_detached", "project",
                "--workspace", "ws_main", "--screen", "screen_1", "--pane", "pane_1",
                "--index", "2",
            ]
        )
    }

    @Test func terminalProjectionArgvCanFenceAConcurrentSnapshotMutation() {
        let target = CloudTuiTerminalProjectionTarget(
            workspaceID: "ws_main", screenID: "screen_1", paneID: "pane_1", index: 0
        )
        #expect(
            CloudTuiCommandLine.projectTerminalArguments(
                socketPath: "/k.sock",
                terminalID: "term_detached",
                target: target,
                expectedRevision: "42",
                idempotencyKey: "projection-1"
            ).suffix(4).elementsEqual([
                "--expected-revision", "42", "--idempotency-key", "projection-1"
            ])
        )
    }

    @Test func resourceRevisionAcceptsOnlyDecimalSnapshotCursors() {
        #expect(
            CmuxTuiSnapshotParser.resourceRevision(
                from: ["cursor": ["revision": "42"]]
            ) == "42"
        )
        #expect(
            CmuxTuiSnapshotParser.resourceRevision(
                from: ["cursor": ["revision": "1.0"]]
            ) == nil
        )
        #expect(CmuxTuiSnapshotParser.resourceRevision(from: [:]) == nil)
    }

    @Test func synchronizableStateRejectsDuplicateIdentityRows() {
        var snapshot = Self.sessionSnapshot
        snapshot["cursor"] = ["generation": "g1", "revision": "1"]

        var duplicateTabs = snapshot
        duplicateTabs["tabs"] = (Self.sessionSnapshot["tabs"] as! [[String: Any]]) + [
            ["id": "tab_1", "pane_id": "pane_2", "content_kind": "terminal", "content_id": "term_shell"],
        ]
        #expect(CmuxTuiSnapshotParser.state(fromSnapshot: duplicateTabs, machine: Self.machine) == nil)

        var duplicateTerminals = snapshot
        duplicateTerminals["terminals"] = (Self.sessionSnapshot["terminals"] as! [[String: Any]]) + [
            ["id": "term_build", "tab_ids": ["tab_1"], "title": "ambiguous", "lifecycle": "running"],
        ]
        #expect(CmuxTuiSnapshotParser.state(fromSnapshot: duplicateTerminals, machine: Self.machine) == nil)

        var missingIdentity = snapshot
        missingIdentity["tabs"] = [
            ["pane_id": "pane_1", "content_kind": "terminal", "content_id": "term_build"],
        ]
        #expect(CmuxTuiSnapshotParser.state(fromSnapshot: missingIdentity, machine: Self.machine) == nil)

        var missingRelationship = snapshot
        missingRelationship["screens"] = [["id": "screen_1"]]
        #expect(CmuxTuiSnapshotParser.state(fromSnapshot: missingRelationship, machine: Self.machine) == nil)

        var missingAgentIdentity = snapshot
        missingAgentIdentity["agents"] = [["terminal_id": "term_build", "state": "working"]]
        let legacyAgentState = CmuxTuiSnapshotParser.state(fromSnapshot: missingAgentIdentity, machine: Self.machine)
        #expect(legacyAgentState?.agents == [CloudVMAgentState(id: nil, terminalID: "term_build", state: "working", source: nil)])

        var duplicateAgentIDs = snapshot
        duplicateAgentIDs["agents"] = (Self.sessionSnapshot["agents"] as! [[String: Any]]) + [
            ["id": "agent_1", "terminal_id": "term_shell", "state": "working"],
        ]
        #expect(CmuxTuiSnapshotParser.state(fromSnapshot: duplicateAgentIDs, machine: Self.machine) == nil)

        var conflictingAgents = snapshot
        conflictingAgents["agents"] = (Self.sessionSnapshot["agents"] as! [[String: Any]]) + [
            ["id": "agent_2", "terminal_id": "term_build", "state": "blocked", "source": "hook"],
        ]
        #expect(CmuxTuiSnapshotParser.state(fromSnapshot: conflictingAgents, machine: Self.machine) == nil)

        // A repeated tab reference in one terminal is harmless to identity, but
        // it must not produce duplicate rename targets or duplicate tree rows.
        var repeatedReference = snapshot
        repeatedReference["terminals"] = [
            ["id": "term_build", "tab_ids": ["tab_1", "tab_1"], "title": "one", "lifecycle": "running"],
        ]
        let state = CmuxTuiSnapshotParser.state(fromSnapshot: repeatedReference, machine: Self.machine)
        #expect(state?.terminals.first?.tabIDs == ["tab_1"])

        // A tab that exists but claims another content identity is not a
        // recoverable placement error. Accepting it would route a rename to
        // the wrong terminal, so the complete graph is rejected and the
        // provider must fetch a fresh snapshot.
        var mismatchedTerminalTab = snapshot
        mismatchedTerminalTab["terminals"] = [
            ["id": "term_build", "tab_ids": ["tab_2"], "title": "wrong", "lifecycle": "running"],
        ]
        #expect(CmuxTuiSnapshotParser.state(fromSnapshot: mismatchedTerminalTab, machine: Self.machine) == nil)

        var mismatchedBrowserTab = snapshot
        mismatchedBrowserTab["browsers"] = [
            ["id": "browser_1", "tab_id": "tab_1", "url": "http://localhost:3000", "title": "wrong"],
        ]
        #expect(CmuxTuiSnapshotParser.state(fromSnapshot: mismatchedBrowserTab, machine: Self.machine) == nil)

        // Older daemons encode an absent multi-tab relationship as JSON null.
        // The singular tab_id remains enough to retain the placement.
        var nullTabIDs = snapshot
        nullTabIDs["terminals"] = [
            ["id": "term_build", "tab_ids": NSNull(), "tab_id": "tab_1", "title": "build", "lifecycle": "running"],
        ]
        let nullTabIDsState = CmuxTuiSnapshotParser.state(fromSnapshot: nullTabIDs, machine: Self.machine)
        #expect(nullTabIDsState?.terminals.first?.tabIDs == ["tab_1"])
    }

    @Test func synchronizableStateRejectsMissingGraphCollections() {
        let requiredCollections = ["workspaces", "screens", "panes", "tabs", "terminals", "browsers", "agents"]
        for key in requiredCollections {
            var truncated = Self.sessionSnapshot
            truncated["cursor"] = ["generation": "g1", "revision": "1"]
            truncated.removeValue(forKey: key)
            #expect(
                CmuxTuiSnapshotParser.state(fromSnapshot: truncated, machine: Self.machine) == nil,
                "a snapshot missing \(key) must not replace the installed graph"
            )
        }
    }

    @Test func resourceKindWireFormAcceptsTheOldScreenName() throws {
        #expect(SurfaceResourceKind(wire: "display") == .display)
        #expect(SurfaceResourceKind(wire: "screen") == .display, "pre-rename apps and persisted sessions say screen")
        #expect(SurfaceResourceKind(wire: "terminal") == .terminal)
        #expect(SurfaceResourceKind(wire: "bogus") == nil)
        #expect(SurfaceResourceKind.display.rawValue == "display", "the emitted wire form is display")

        let old = try #require(SurfaceResourceID(rawValue: "vivid-newt/screen/display:1"))
        #expect(old.kind == .display)
        #expect(old.rawValue == "vivid-newt/display/display:1", "old ids re-emit as display")
        let decoded = try JSONDecoder().decode(SurfaceResourceKind.self, from: Data(#""screen""#.utf8))
        #expect(decoded == .display)
    }

    @Test func exitedTerminalWithoutATabIsNotASurface() {
        // cmux-tui keeps the record of a terminal whose process exited after its tab went
        // away; its selector no longer resolves, so nothing could open or close it.
        var snapshot = Self.sessionSnapshot
        var terminals = snapshot["terminals"] as! [[String: Any]]
        terminals.append(["id": "term_gone", "tab_id": NSNull(), "tab_ids": [], "title": "", "lifecycle": "exited", "running": false,
                          "exit": ["outcome": ["kind": "exit", "code": 130]]])
        snapshot["terminals"] = terminals
        let keys = CmuxTuiSnapshotParser.terminals(fromSnapshot: snapshot, machine: Self.machine).map { $0.id.key }
        #expect(!keys.contains("term_gone"))
        // An exited terminal that still has a tab stays: that one can be closed.
        #expect(keys.contains("term_shell"))
        let tabs = CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: snapshot)
        #expect(tabs["term_shell"] == "tab_2")
        #expect(tabs["term_build"] == "tab_1")
        #expect(tabs["term_gone"] == nil)
    }

    @Test func createdWorkspaceResultCarriesItsFirstTerminal() throws {
        let result: [String: Any] = ["value": ["kind": "terminal", "workspace_id": "ws_new", "terminal_id": "term_first", "tab_id": "tab_x"]]
        let created = try #require(CmuxTuiSnapshotParser.createdWorkspaceTerminal(fromResult: result))
        #expect(created.workspaceID == "ws_new")
        #expect(created.terminalID == "term_first")
        #expect(CmuxTuiSnapshotParser.createdWorkspaceTerminal(fromResult: ["value": ["workspace_id": ""]]) == nil)
        #expect(CmuxTuiSnapshotParser.createdWorkspaceTerminal(fromResult: ["workspace_id": "ws_bare"])?.terminalID == nil)
    }

    @Test func closeArgvFollowsTheCLIGrammar() {
        #expect(CloudTuiCommandLine.closeTerminalArguments(socketPath: "/tmp/s.sock", terminalID: "term_1")
            == ["--socket", "/tmp/s.sock", "--json", "terminal", "term_1", "close"])
        #expect(CloudTuiCommandLine.closeTabArguments(socketPath: "/tmp/s.sock", tabID: "tab_1")
            == ["--socket", "/tmp/s.sock", "--json", "tab", "tab_1", "close"])
        #expect(CloudTuiCommandLine.closeWorkspaceArguments(socketPath: "/tmp/s.sock", workspaceID: "ws_1")
            == ["--socket", "/tmp/s.sock", "--json", "workspace", "ws_1", "close"])
    }

    @Test func headlessTerminalIOArgvFollowsTheCLIGrammar() {
        // Verified live against a machine: `write --text` types as-is (no newline),
        // `keys` takes bare key names, `screen read` / `screen wait --pattern` read back.
        #expect(CloudTuiCommandLine.writeArguments(socketPath: "/tmp/s.sock", terminalID: "term_1", text: "echo hi $((6*7))")
            == ["--socket", "/tmp/s.sock", "--json", "terminal", "term_1", "write", "--text", "echo hi $((6*7))"])
        #expect(CloudTuiCommandLine.keysArguments(socketPath: "/tmp/s.sock", terminalID: "term_1", keys: ["ctrl+c", "enter"])
            == ["--socket", "/tmp/s.sock", "--json", "terminal", "term_1", "keys", "ctrl+c", "enter"])
        #expect(CloudTuiCommandLine.screenReadArguments(socketPath: "/tmp/s.sock", terminalID: "term_1")
            == ["--socket", "/tmp/s.sock", "--json", "terminal", "term_1", "screen", "read"])
        #expect(CloudTuiCommandLine.screenWaitArguments(socketPath: "/tmp/s.sock", terminalID: "term_1", pattern: "pass|fail", timeoutMs: 5000)
            == ["--socket", "/tmp/s.sock", "--json", "terminal", "term_1", "screen", "wait", "--pattern", "pass|fail", "--timeout-ms", "5000"])
        // No timeout (or a non-positive one) leaves the daemon default in charge.
        #expect(CloudTuiCommandLine.screenWaitArguments(socketPath: "/tmp/s.sock", terminalID: "term_1", pattern: "λ", timeoutMs: nil).contains("--timeout-ms") == false)
        #expect(CloudTuiCommandLine.screenWaitArguments(socketPath: "/tmp/s.sock", terminalID: "term_1", pattern: "λ", timeoutMs: 0).contains("--timeout-ms") == false)
    }

    @Test @MainActor func waitTimeoutNormalizesToTheDaemonDefaultAndClamps() {
        // The link headroom is computed from the same value the daemon uses, so a
        // non-positive request cannot cut the link off before the daemon's default.
        #expect(CmuxTuiSurfaceProvider.clampedWaitTimeoutMs(nil) == CmuxTuiSurfaceProvider.defaultWaitTimeoutMs)
        #expect(CmuxTuiSurfaceProvider.clampedWaitTimeoutMs(0) == CmuxTuiSurfaceProvider.defaultWaitTimeoutMs)
        #expect(CmuxTuiSurfaceProvider.clampedWaitTimeoutMs(-5) == CmuxTuiSurfaceProvider.defaultWaitTimeoutMs)
        #expect(CmuxTuiSurfaceProvider.clampedWaitTimeoutMs(1) == 1)
        #expect(CmuxTuiSurfaceProvider.clampedWaitTimeoutMs(Int.max) == CmuxTuiSurfaceProvider.maxWaitTimeoutMs)
    }

    @Test func emptyAndMalformedSnapshotsProduceNothing() {
        #expect(CmuxTuiSnapshotParser.terminals(fromSnapshot: [:], machine: Self.machine).isEmpty)
        #expect(CmuxTuiSnapshotParser.terminals(fromSnapshot: ["workspaces": [["name": "no id"]]], machine: Self.machine).isEmpty)
        #expect(CmuxTuiSnapshotParser.terminal(fromSnapshotEntry: ["title": "no id"], machine: Self.machine) == nil)
    }

    @Test func mutationResultsAndLinkLinesParse() {
        let wrapped: [String: Any] = [
            "value": ["kind": "terminal", "workspace_id": "ws_main", "screen_id": "screen_1", "pane_id": "pane_1", "tab_id": "tab_9", "terminal_id": "term_new"],
            "generation": "g1", "revision": "42", "replayed": false,
        ]
        let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: wrapped)
        #expect(created?.terminalID == "term_new")
        #expect(created?.workspaceID == "ws_main")
        #expect(created?.cursor == CloudVMCursor(generation: "g1", revision: 42))
        #expect(CmuxTuiSnapshotParser.mutationCursor(fromResult: ["generation": "g1", "revision": true]) == nil)
        #expect(CmuxTuiSnapshotParser.mutationCursor(fromResult: ["terminal_id": "term_bare"]) == nil)
        #expect(
            CmuxTuiSnapshotParser.mutationCursor(
                fromResult: ["result": ["value": [:], "generation": "g2", "revision": "7"]]
            ) == CloudVMCursor(generation: "g2", revision: 7)
        )
        #expect(
            CmuxTuiSnapshotParser.mutationCursor(
                fromResult: ["cursor": ["generation": "g3", "revision": "8"]]
            ) == CloudVMCursor(generation: "g3", revision: 8)
        )
        #expect(
            CmuxTuiSnapshotParser.mutationCursor(
                fromResult: ["revision": "9"],
                fallbackGeneration: "g4"
            ) == CloudVMCursor(generation: "g4", revision: 9)
        )
        #expect(CmuxTuiSnapshotParser.createdTerminal(fromRunResult: ["terminal_id": "term_bare"])?.terminalID == "term_bare")
        #expect(CmuxTuiSnapshotParser.createdTerminal(fromRunResult: ["value": ["kind": "terminal"]]) == nil)
        #expect(CmuxTuiSnapshotParser.createdWorkspace(fromResult: ["value": ["workspace_id": "ws_9"]]) == "ws_9")
        #expect(CmuxTuiSnapshotParser.createdWorkspace(fromResult: ["id": "ws_bare"]) == "ws_bare")
        #expect(CmuxTuiSnapshotParser.createdWorkspace(fromResult: ["value": [:]]) == nil)

        #expect(CmuxTuiSnapshotParser.localSocket(fromLinkLine: #"{"event":"connection-snapshot","local_socket":"/tmp/x/mux.sock","connection":{}}"#) == "/tmp/x/mux.sock")
        #expect(CmuxTuiSnapshotParser.localSocket(fromLinkLine: #"{"event":"other","local_socket":"/tmp/x"}"#) == nil)
        #expect(CmuxTuiSnapshotParser.localSocket(fromLinkLine: "not json") == nil)
    }

    @Test func listeningPortsScreensDesktopAndPortBrowsers() {
        let ss = """
        State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port Process
        LISTEN  0       4096    0.0.0.0:3000        0.0.0.0:*
        LISTEN  0       128     [::]:1337           [::]:*
        LISTEN  0       128     127.0.0.1:5901      0.0.0.0:*
        LISTEN  0       128     0.0.0.0:3000        0.0.0.0:*
        """
        #expect(CmuxTuiSnapshotParser.listeningPorts(fromSocketListing: ss) == [1337, 3000, 5901])
        #expect(CmuxTuiSnapshotParser.internalPorts.isSuperset(of: [1337, 5901, 6901]))
        #expect(CmuxTuiSnapshotParser.machineHasDesktop(image: "cmux-xfce-vnc:latest"))
        #expect(!CmuxTuiSnapshotParser.machineHasDesktop(image: "cmuxd-ws:tooling-20260509f"))

        let display = CmuxTuiSnapshotParser.display(machine: Self.machine)
        #expect(display.id == SurfaceResourceID(machine: Self.machine, kind: .display, key: "display:1"))
        #expect(display.id.rawValue == "vivid-newt/display/display:1")
        #expect(display.port == 6901)
        let port = CmuxTuiSnapshotParser.portBrowser(machine: Self.machine, port: 3000)
        #expect(port.id.rawValue == "vivid-newt/browser/port:3000")
        #expect(port.title == ":3000")
        #expect(CmuxTuiSnapshotParser.desktopURL(openURL: "http://localhost:3777/vm/desktop/m?cmux_token=t") == "http://localhost:3777/vm/desktop/m?cmux_token=t&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000")
    }

    @Test func clientArgvIsExact() {
        // A machine's trusted listener is dialed with --carrier: no invite file, no enrollment.
        #expect(CloudTuiCommandLine.linkArguments(route: "wss://m.vm.cmux.sh/v1/link?t=1", deviceName: "cmux-mac", stateDir: "/s", carrier: true) ==
            ["remote", "connect", "wss://m.vm.cmux.sh/v1/link?t=1", "--device-name", "cmux-mac", "--state-dir", "/s", "--headless", "--json", "--exit-with-parent", "--carrier"])
        // A machine this Mac enrolled with before trusted listeners presents its stored key.
        #expect(CloudTuiCommandLine.linkArguments(route: "r", deviceName: "d", stateDir: "/s") ==
            ["remote", "connect", "r", "--device-name", "d", "--state-dir", "/s", "--headless", "--json", "--exit-with-parent"])
        // A private-network machine dials through the app's WireGuard hub. Both long-lived
        // helper processes must also stop if their app parent exits without cleanup.
        #expect(CloudTuiCommandLine.linkArguments(route: "ws://[fd00::10]:1337/v1/link", deviceName: "d", stateDir: "/s", carrier: true, wireguardHubSocket: "/h.sock") ==
            ["remote", "connect", "ws://[fd00::10]:1337/v1/link", "--device-name", "d", "--state-dir", "/s", "--headless", "--json", "--exit-with-parent", "--carrier", "--wireguard-hub", "/h.sock"])
        #expect(CloudTuiCommandLine.linkArguments(route: "r", deviceName: "d", stateDir: "/s", wireguardHubSocket: "") ==
            ["remote", "connect", "r", "--device-name", "d", "--state-dir", "/s", "--headless", "--json", "--exit-with-parent"])
        #expect(CloudTuiCommandLine.wireGuardHubArguments(configPath: "/w/cmux-app.conf", socketPath: "/w/hub-1.sock") ==
            ["wg", "hub", "--config", "/w/cmux-app.conf", "--socket", "/w/hub-1.sock", "--exit-with-parent"])
        #expect(CloudTuiCommandLine.snapshotArguments(socketPath: "/k.sock") == ["--socket", "/k.sock", "--json", "session", "current", "snapshot"])
        #expect(CloudTuiCommandLine.eventsArguments(socketPath: "/k.sock") == ["--socket", "/k.sock", "--jsonl", "session", "current", "events"])
        #expect(CloudTuiCommandLine.runArguments(socketPath: "/k.sock", workspaceID: "ws_main", command: ["claude", "-p", "fix it"]) ==
            ["--socket", "/k.sock", "--json", "workspace", "ws_main", "run", "--", "claude", "-p", "fix it"])
        #expect(CloudTuiCommandLine.attachArguments(socketPath: "/k.sock", terminalID: "term_1") == ["--socket", "/k.sock", "attach", "--terminal", "term_1"])
        #expect(CloudTuiCommandLine.attachShellCommand(clientPath: "/Applications/cmux DEV.app/Contents/Resources/bin/cmux-tui", socketPath: "/k.sock", terminalID: "term_1") ==
            "'/Applications/cmux DEV.app/Contents/Resources/bin/cmux-tui' --socket /k.sock attach --terminal term_1")
        #expect(CloudTuiCommandLine.commandStartingIn(cwd: nil, command: ["bash", "-l"]) == ["bash", "-l"])
        #expect(CloudTuiCommandLine.commandStartingIn(cwd: "/root/work/my app", command: ["codex", "exec", "it's"]) ==
            ["sh", "-lc", "cd '/root/work/my app' && exec codex exec 'it'\\''s'"])
        // Rename takes the name via --name (verified live; positional is usage.invalid).
        #expect(CloudTuiCommandLine.renameWorkspaceArguments(socketPath: "/k.sock", workspaceID: "ws_main", name: "backend work") ==
            ["--socket", "/k.sock", "--json", "workspace", "ws_main", "rename", "--name", "backend work"])
        #expect(CloudTuiCommandLine.renameWorkspaceArguments(socketPath: "/k.sock", workspaceID: "ws_main", name: "backend work", expectedRevision: 7) ==
            ["--socket", "/k.sock", "--json", "--expected-revision", "7", "workspace", "ws_main", "rename", "--name", "backend work"])
        // Verified live: the flat `set-default-colors` verb is `usage.invalid` in the v2
        // resource CLI; the session-scoped form below is the one machines accept.
        #expect(CloudTuiCommandLine.setDefaultColorsArguments(socketPath: "/k.sock", foreground: "#d8dee9", background: "#171b2e") ==
            ["--socket", "/k.sock", "--json", "session", "current", "terminal", "defaults", "set", "--foreground", "#d8dee9", "--background", "#171b2e"])
        #expect(CloudTuiCommandLine.setDefaultColorsArguments(socketPath: "/k.sock", foreground: nil, background: "#171b2e") ==
            ["--socket", "/k.sock", "--json", "session", "current", "terminal", "defaults", "set", "--background", "#171b2e"])
        // No colors, no command: pushing an empty defaults update would be a no-op round trip.
        #expect(CloudTuiCommandLine.setDefaultColorsArguments(socketPath: "/k.sock", foreground: nil, background: nil) == nil)
        #expect(CloudTuiCommandLine.renameTabArguments(socketPath: "/k.sock", tabID: "tab_1", name: "db shell") ==
            ["--socket", "/k.sock", "--json", "tab", "tab_1", "rename", "--name", "db shell"])
        // The daemon treats an empty tab name as a clear operation. Keep the
        // empty token in argv so this stays distinct from a missing value.
        #expect(CloudTuiCommandLine.renameTabArguments(socketPath: "/k.sock", tabID: "tab_1", name: "") ==
            ["--socket", "/k.sock", "--json", "tab", "tab_1", "rename", "--name", ""])
        #expect(CloudRemoteRenameName(rawValue: " \n") == .cleared)
        #expect(CloudRemoteRenameName(rawValue: "  db shell  ").wireValue == "db shell")
        #expect(CloudTuiCommandLine.renameTabArguments(socketPath: "/k.sock", tabID: "tab_1", name: "db shell", expectedRevision: 9) ==
            ["--socket", "/k.sock", "--json", "--expected-revision", "9", "tab", "tab_1", "rename", "--name", "db shell"])
    }

    @Test func socketRenameParameterPreservesExplicitEmptyValue() {
        #expect(TerminalController.surfaceString("") == nil)
        #expect(TerminalController.surfaceStringPreservingEmpty("") == "")
        #expect(TerminalController.surfaceStringPreservingEmpty("  \n") == "")
        #expect(TerminalController.surfaceStringPreservingEmpty(NSNull()) == nil)
        #expect(TerminalController.surfaceStringPreservingEmpty("  db shell  ") == "db shell")
    }

    @Test func clientPathsMirrorTheCLI() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-cloud-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = CloudTuiClientPaths(home: home)
        #expect(paths.stateDir.path == home.appendingPathComponent(".cmuxterm/cmux-tui-client").path)
        #expect(paths.devicesStoreURL.path == home.appendingPathComponent(".cmuxterm/vm-tui-devices.json").path)
        #expect(paths.deviceFingerprint(for: "vivid-newt") == nil)
        paths.saveDeviceFingerprint("fp-1", for: "vivid-newt")
        #expect(paths.deviceFingerprint(for: "vivid-newt") == "fp-1")
        // Same JSON shape the CLI's `saveVMTuiDevice` writes.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.devicesStoreURL)) as? [String: [String: Any]]
        #expect(raw?["vivid-newt"]?["deviceFingerprint"] as? String == "fp-1")
        #expect(raw?["vivid-newt"]?["updatedAtUnix"] != nil)
        #expect(CloudTuiClientPaths.deviceName(hostName: "Austin's MacBook.local").hasPrefix("cmux-Austin-s-MacBook"))
    }

    @Test @MainActor func optimisticPanePlaceholdersLabelAndEscape() {
        #expect(CmuxTuiSurfaceProvider.paneLabel(machineID: "vivid-newt", port: 6901, desktop: true) == "vivid-newt · Desktop")
        #expect(CmuxTuiSurfaceProvider.paneLabel(machineID: "vivid-newt", port: 3000, desktop: false) == "vivid-newt:3000")
        let connecting = SurfaceBrowserPlaceholder.connecting("vivid-newt · Desktop")
        #expect(connecting.contains("Connecting to vivid-newt · Desktop…"))
        #expect(connecting.contains("class=\"spinner\""))
        #expect(connecting.contains("#1f2430"), "the desktop's own background, not a white tab")
        let failed = SurfaceBrowserPlaceholder.failed("<m>:3000", error: "HTTP 503 <vm_image_unavailable> & more")
        #expect(failed.contains("Couldn’t open &lt;m&gt;:3000"))
        #expect(failed.contains("HTTP 503 &lt;vm_image_unavailable&gt; &amp; more"))
        #expect(!failed.contains("<vm_image_unavailable>"))
        // No spinner ELEMENT in the failed state; the shared stylesheet still declares
        // `.spinner`, so a bare substring check would always fail.
        #expect(!failed.contains("class=\"spinner\""))
        #expect(failed.contains("open it again from the sidebar"))
        #expect(SurfaceBrowserPlaceholder.escape("a\"b'c") == "a&quot;b&#39;c")
    }

    @Test func linkPipesReadOnGCDNotCooperativeThreads() async throws {
        // Lines arrive as the child writes them, a trailing CR is dropped, and an
        // unterminated last line is delivered at EOF.
        let pipe = Pipe()
        let lines = CloudLinkPipe.lines(from: pipe.fileHandleForReading)
        let writer = pipe.fileHandleForWriting
        writer.write(Data("{\"a\":1}\nsecond\r\npart".utf8))
        writer.write(Data("ial\n".utf8))
        writer.write(Data("tail".utf8))
        try writer.close()
        var received: [String] = []
        for await line in lines { received.append(line) }
        #expect(received == ["{\"a\":1}", "second", "partial", "tail"])

        let split = CloudLinkPipe.splitLines(Data("x\ny\r\nz".utf8))
        #expect(split.lines == ["x", "y"])
        #expect(String(decoding: split.rest, as: UTF8.self) == "z")

        let whole = Pipe()
        whole.fileHandleForWriting.write(Data("all of it".utf8))
        try whole.fileHandleForWriting.close()
        let data = await CloudLinkPipe.readToEnd(whole.fileHandleForReading)
        #expect(String(decoding: data, as: UTF8.self) == "all of it")
    }

    @Test func linkFirstValueResolvesOnce() async {
        let socket = CloudLinkFirstValue<String>()
        async let awaited = socket.result
        socket.resolve("/tmp/a.sock")
        socket.resolve("/tmp/b.sock")
        #expect(await awaited == "/tmp/a.sock")
        #expect(await socket.result == "/tmp/a.sock", "later awaits see the same value")
        let eof = CloudLinkFirstValue<String>()
        eof.resolve(nil)
        #expect(await eof.result == nil, "finished without a value reads as nil")
    }

    @Test func cancellingLinkCommandStopsItsChildBeforeReturning() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cloud-command-\(UUID().uuidString.lowercased()).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let link = CloudMachineLink(
            machineID: "test-machine",
            clientURL: URL(fileURLWithPath: "/bin/sh"),
            paths: CloudTuiClientPaths()
        )
        let task = Task {
            try await link.run(
                arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec /bin/sleep 30"],
                timeout: .seconds(60)
            )
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(rawPID))
        defer { _ = Darwin.kill(pid, SIGKILL) }

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled link command must throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("a cancelled link command returned \(error) instead of CancellationError")
        }
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "the child must be reaped before run returns")
    }

    @Test func cancellingLinkConnectStopsItsChildBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cloud-connect-cancel-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("link.pid")
        let client = root.appendingPathComponent("fake-cmux-tui")
        try """
        #!/bin/sh
        echo $$ > '\(pidFile.path)'
        exec /bin/sleep 30
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let link = CloudMachineLink(
            machineID: "test-machine",
            clientURL: client,
            paths: CloudTuiClientPaths(home: root)
        )
        let task = Task {
            try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main")
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = Darwin.kill(pid, SIGKILL) }

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled link connect must throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("a cancelled link connect returned \(error) instead of CancellationError")
        }
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "the link child must be reaped before connect returns")
    }

    @Test func linkClientExitingBeforeItsSocketLineReportsTheExitNotATimeout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cloud-connect-exit-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("fake-cmux-tui")
        // An older bundled client that does not know a flag exits at once with a
        // usage error and never prints a connection snapshot.
        try """
        #!/bin/sh
        echo 'cmux-tui: unknown option "--carrier"' >&2
        exit 2
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let link = CloudMachineLink(
            machineID: "test-machine",
            clientURL: client,
            paths: CloudTuiClientPaths(home: root)
        )
        // The error kind is the whole check: before the fix this path threw
        // `timedOut` the moment stdout closed, so a wall-clock bound adds nothing
        // and only measures how fast the host spawns a fresh script.
        do {
            _ = try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main", carrier: true, timeout: .seconds(60))
            Issue.record("a client that exits before its socket line must fail the connect")
        } catch CloudMachineLink.LinkError.exited(let status, let output) {
            #expect(status == 2)
            #expect(output.contains("unknown option"), "the client's stderr must reach the error: \(output)")
        } catch {
            Issue.record("expected LinkError.exited, got \(error)")
        }
    }

    @Test func disconnectStopsLinkAndEventChildrenBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cloud-disconnect-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let linkPIDFile = root.appendingPathComponent("link.pid")
        let eventPIDFile = root.appendingPathComponent("event.pid")
        let client = root.appendingPathComponent("fake-cmux-tui")
        try """
        #!/bin/sh
        if [ "$1" = "remote" ]; then
          echo $$ > '\(linkPIDFile.path)'
          echo '{"event":"connection-snapshot","local_socket":"/tmp/fake-cloud-link.sock","connection":{}}'
        else
          echo $$ > '\(eventPIDFile.path)'
        fi
        exec /bin/sleep 30
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let link = CloudMachineLink(
            machineID: "test-machine",
            clientURL: client,
            paths: CloudTuiClientPaths(home: root)
        )
        _ = try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: eventPIDFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let linkPID = try #require(Int32(try String(contentsOf: linkPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let eventPID = try #require(Int32(try String(contentsOf: eventPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer {
            _ = Darwin.kill(linkPID, SIGKILL)
            _ = Darwin.kill(eventPID, SIGKILL)
        }

        await link.disconnect()

        #expect(Darwin.kill(linkPID, 0) == -1 && errno == ESRCH, "disconnect must reap the link child")
        #expect(Darwin.kill(eventPID, 0) == -1 && errno == ESRCH, "disconnect must reap the event child")
    }

    @Test func displayTabsPointWorkspacesAtTheMachineScreen() throws {
        var snapshot = Self.sessionSnapshot
        var tabs = snapshot["tabs"] as! [[String: Any]]
        tabs.append(["id": "tab_desk", "pane_id": "pane_2", "content_kind": "display", "content_id": "display:1"])
        snapshot["tabs"] = tabs
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: snapshot, machine: Self.machine)
        let display = try #require(resources.first { $0.kind == .display })
        #expect(display.id.key == "display:1", "the pool's own id, so the pointer and the pool entry are one resource")
        #expect(display.remoteWorkspaces.map(\.id) == ["ws_api"])
        #expect(display.remoteViews?.map(\.tabID) == ["tab_desk"])
        #expect(display.port == CmuxTuiSnapshotParser.desktopPort)
        // Closing the pointer closes its tab (a display has no process to end).
        #expect(CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: snapshot)["display:1"] == "tab_desk")
        // The pool entry yields to the pointed one; a machine nobody points at keeps the bare entry.
        let pool = [CmuxTuiSnapshotParser.display(machine: Self.machine)]
        let merged = CmuxTuiSnapshotParser.mergingDisplays(pool: pool, parsed: resources)
        #expect(merged.filter { $0.kind == .display }.count == 1)
        #expect(merged.first { $0.kind == .display }?.remoteViews?.isEmpty == false)
        let untouched = CmuxTuiSnapshotParser.mergingDisplays(pool: pool, parsed: resources.filter { $0.kind != .display })
        #expect(untouched.filter { $0.kind == .display }.count == 1)
        #expect(untouched.first { $0.kind == .display }?.remoteViews == nil)

        // Older daemon snapshots called the VNC pointer a screen. The wire
        // alias must still project the same display resource.
        tabs[tabs.count - 1]["content_kind"] = "screen"
        snapshot["tabs"] = tabs
        let legacyDisplay = try #require(
            CmuxTuiSnapshotParser.terminals(fromSnapshot: snapshot, machine: Self.machine)
                .first { $0.kind == .display }
        )
        #expect(legacyDisplay.remoteViews?.map(\.tabID) == ["tab_desk"])
    }

    @Test func revisionedStateRetainsTheWholeRemoteDocumentAndAppliesTabDelta() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["cursor"] = [
            "generation": "daemon-a",
            "revision": "7",
            "future_cursor_field": ["lease": "keep-me"],
        ]
        snapshot["future_scalar"] = true
        snapshot["clients"] = [["id": "client-1", "session_id": "session-1", "transport": "unix"]]
        snapshot["notifications"] = [["id": "notice-1", "title": "Build", "body": "done"]]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        #expect(state.cursor == CloudVMCursor(generation: "daemon-a", revision: 7))
        #expect(state.tabs.first { $0.id == "tab_1" }?.name == nil)
        #expect(state.panes.first { $0.id == "pane_1" }?.tabIDs == ["tab_1", "tab_3"])
        #expect(state.entity(kind: "clients", id: "client-1") != nil)
        #expect(state.entity(kind: "notifications", id: "notice-1") != nil)
        #expect(state.entity(kind: "tab", id: "tab_1")?.kind == "tabs")
        #expect(state.entities(kind: "tabs").count == 4)
        #expect(state.entities(kind: "cursor").isEmpty)
        #expect(!state.otherEntities.contains { $0.kind == "cursor" })
        let futureScalar = try #require(state.otherEntities.first { $0.kind == "future_scalar" })
        #expect(state.agentEntityObject(futureScalar) as? Bool == true)
        #expect(state.snapshotObject()?["clients"] as? [[String: Any]] != nil)

        let deltaObject: [String: Any] = [
            "kind": "delta",
            "previous_revision": "7",
            "revision": "8",
            "changes": [[
                "kind": "upsert",
                "resource": "tab",
                "id": "tab_1",
                "value": [
                    "id": "tab_1", "pane_id": "pane_1", "name": "renamed",
                    "content_kind": "terminal", "content_id": "term_build", "index": 0, "focused": true,
                ],
            ], [
                "kind": "upsert",
                "resource": "notification",
                "id": "notice-1",
                "value": [
                    "id": "notice-1", "title": "Build", "body": "passed", "unread": false,
                ],
            ]],
        ]
        let deltaData = try JSONSerialization.data(withJSONObject: deltaObject)
        let next = try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: deltaData,
            cursor: CloudVMCursor(generation: "daemon-a", revision: 8),
            to: state
        ))
        #expect(next.cursor == CloudVMCursor(generation: "daemon-a", revision: 8))
        let nextCursor = try #require(next.snapshotObject()?["cursor"] as? [String: Any])
        #expect(nextCursor["future_cursor_field"] as? [String: String] == ["lease": "keep-me"])
        #expect(next.tabs.first { $0.id == "tab_1" }?.name == "renamed")
        let terminal = try #require(CmuxTuiSnapshotParser.resources(from: next).first { $0.id.key == "term_build" })
        #expect(terminal.remoteViews?.first?.name == "renamed")
        #expect(terminal.title == "cargo test")
        let targetedTerminal = try #require(CmuxTuiSnapshotParser.resources(
            from: next,
            matching: [SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_build")]
        ).first)
        #expect(targetedTerminal.remoteViews?.first?.name == "renamed")
        #expect(targetedTerminal.title == "cargo test")
        #expect(next.lookupIndex.tab(id: "tab_1")?.name == "renamed")
        #expect(next.lookupIndex.terminal(id: "term_build")?.tabIDs == ["tab_1", "tab_4"])
        #expect(next.lookupIndex.agent(terminalID: "term_build")?.state == "working")
        let notification = try #require(next.entity(kind: "notification", id: "notice-1"))
        let notificationObject = try #require(JSONSerialization.jsonObject(with: notification.payload) as? [String: Any])
        #expect(notificationObject["body"] as? String == "passed")

        let application = try #require(CmuxTuiSnapshotParser.applyingWithImpact(
            deltaPayload: deltaData,
            cursor: CloudVMCursor(generation: "daemon-a", revision: 8),
            to: state
        ))
        #expect(application.impact.resourceIDs.contains(SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_build")))
        #expect(!application.impact.requiresFullResourceRebuild)
    }

    @Test func tabMoveUpdatesBothTerminalViewListsFromOneDelta() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["cursor"] = ["generation": "daemon-a", "revision": "7"]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        let delta: [String: Any] = [
            "kind": "delta",
            "previous_revision": "7",
            "revision": "8",
            "changes": [[
                "kind": "upsert",
                "resource": "tab",
                "id": "tab_4",
                "value": [
                    "id": "tab_4", "pane_id": "pane_2", "name": "moved",
                    "content_kind": "terminal", "content_id": "term_shell", "index": 1, "focused": false,
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: delta)
        let next = try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: data,
            cursor: CloudVMCursor(generation: "daemon-a", revision: 8),
            to: state
        ))
        #expect(next.lookupIndex.terminal(id: "term_build")?.tabIDs == ["tab_1"])
        #expect(next.lookupIndex.terminal(id: "term_shell")?.tabIDs == ["tab_2", "tab_4"])
        let build = try #require(CmuxTuiSnapshotParser.resources(
            from: next,
            matching: [SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_build")]
        ).first)
        #expect(build.remoteViews?.map(\.tabID) == ["tab_1"])
        let shell = try #require(CmuxTuiSnapshotParser.resources(
            from: next,
            matching: [SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_shell")]
        ).first)
        #expect(shell.remoteViews?.map(\.tabID) == ["tab_2", "tab_4"])
    }

    @Test func rowLocalDeltaPreservesLargeUnknownCollection() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["cursor"] = ["generation": "daemon-a", "revision": "7"]
        snapshot["notifications"] = (0..<300).map { index in
            [
                "id": "notice-\(index)",
                "title": "Build \(index)",
                "body": "pending",
                "metadata": ["attempt": index, "owner": "agent-\(index % 7)"],
            ] as [String: Any]
        }
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        let delta: [String: Any] = [
            "kind": "delta",
            "previous_revision": "7",
            "revision": "8",
            "changes": [[
                "kind": "upsert",
                "resource": "notification",
                "id": "notice-173",
                "value": [
                    "id": "notice-173", "title": "Build 173", "body": "passed",
                    "metadata": ["attempt": 4, "owner": "agent-5"],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: delta)
        let next = try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: data,
            cursor: CloudVMCursor(generation: "daemon-a", revision: 8),
            to: state
        ))
        #expect(next.entities(kind: "notifications").count == 300)
        let changed = try #require(next.entity(kind: "notification", id: "notice-173"))
        let changedObject = try #require(JSONSerialization.jsonObject(with: changed.payload) as? [String: Any])
        #expect(changedObject["body"] as? String == "passed")
        let untouched = try #require(next.entity(kind: "notification", id: "notice-172"))
        let untouchedObject = try #require(JSONSerialization.jsonObject(with: untouched.payload) as? [String: Any])
        #expect(untouchedObject["metadata"] as? [String: Any] != nil)
        #expect(next.otherEntities.contains { $0.kind == "notifications" && $0.id == "notice-173" })
    }

    @Test func deltaUpsertRejectsAnOmittedOptionalCollection() throws {
        // Current daemons emit an empty array for every auxiliary collection.
        // An older or partially deployed daemon may omit one instead. A delta
        // cannot safely create that collection, because its first upsert would
        // look valid while silently losing any rows the snapshot did not carry.
        var snapshot = Self.sessionSnapshot
        snapshot["cursor"] = ["generation": "daemon-a", "revision": "7"]
        snapshot.removeValue(forKey: "notifications")
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        let delta: [String: Any] = [
            "kind": "delta",
            "previous_revision": "7",
            "revision": "8",
            "changes": [[
                "kind": "upsert",
                "resource": "notification",
                "id": "notice-1",
                "value": ["id": "notice-1", "body": "should recover"],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: delta)
        #expect(CmuxTuiSnapshotParser.applying(
            deltaPayload: data,
            cursor: CloudVMCursor(generation: "daemon-a", revision: 8),
            to: state
        ) == nil)
    }

    @Test func fragmentedDocumentMatchesPayloadIdentityAndRejectsAmbiguity() throws {
        var legacyDocument = CloudVMStateDocument(snapshot: [
            "agents": [["terminal_id": "term_build", "state": "working"]],
        ])
        let didUpsertLegacy = legacyDocument.upsert(
            collectionKey: "agents",
            id: "agent_new",
            value: ["id": "agent_new", "terminal_id": "term_build", "state": "working"],
            alternateField: (name: "terminal_id", value: "term_build")
        )
        #expect(didUpsertLegacy)
        // The row still has its positional storage key, but delete addresses
        // the explicit payload id. Identity cannot depend on the map key.
        let didDeleteLegacy = legacyDocument.delete(
            collectionKey: "agents",
            id: "agent_new",
            alternateField: (name: "terminal_id", value: "term_build")
        )
        #expect(didDeleteLegacy)
        #expect(legacyDocument.opaqueEntities(excluding: []).isEmpty)

        var ambiguousDocument = CloudVMStateDocument(snapshot: [
            "notifications": [
                ["id": "notice", "body": "first"],
                ["id": "notice", "body": "second"],
            ],
        ])
        let before = try #require(ambiguousDocument.data())
        let didUpsertAmbiguous = ambiguousDocument.upsert(
            collectionKey: "notifications",
            id: "notice",
            value: ["id": "notice", "body": "replacement"]
        )
        #expect(!didUpsertAmbiguous)
        #expect(ambiguousDocument.data() == before)
        let didDeleteAmbiguous = ambiguousDocument.delete(collectionKey: "notifications", id: "notice")
        #expect(!didDeleteAmbiguous)
        #expect(ambiguousDocument.data() == before)

        // The envelope id and payload id are one identity contract. A mismatch
        // must force snapshot recovery and cannot overwrite an existing row.
        let didUpsertMismatched = ambiguousDocument.upsert(
            collectionKey: "notifications",
            id: "notice",
            value: ["id": "different", "body": "unsafe"]
        )
        #expect(!didUpsertMismatched)
        #expect(ambiguousDocument.data() == before)

        var relationshipDocument = CloudVMStateDocument(snapshot: [
            "agents": [["id": "agent-1", "terminal_id": "term-a", "state": "working"]],
        ])
        let relationshipBefore = try #require(relationshipDocument.data())
        let didDeleteWrongRelationship = relationshipDocument.delete(
            collectionKey: "agents",
            id: "agent-1",
            alternateField: (name: "terminal_id", value: "term-b")
        )
        #expect(!didDeleteWrongRelationship)
        #expect(relationshipDocument.data() == relationshipBefore)

        var missingRelationshipDocument = CloudVMStateDocument(snapshot: [
            "agents": [["id": "agent-1", "state": "working"]],
        ])
        let missingRelationshipBefore = try #require(missingRelationshipDocument.data())
        let didDeleteMissingRelationship = missingRelationshipDocument.delete(
            collectionKey: "agents",
            id: "agent-1",
            alternateField: (name: "terminal_id", value: "term-a")
        )
        #expect(!didDeleteMissingRelationship)
        #expect(missingRelationshipDocument.data() == missingRelationshipBefore)
    }

    @Test func entityLookupUsesCanonicalIdentityAndFailsClosedOnDuplicates() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["notifications"] = (0..<256).map { index in
            [
                "id": "notice-\(index)",
                "body": "Build \(index)",
                "metadata": ["owner": "agent-\(index % 5)"],
            ] as [String: Any]
        }
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        let entity = try #require(state.entity(kind: "notification", id: "notice-173"))
        #expect(entity.kind == "notifications")
        #expect(entity.id == "notice-173")
        let payload = try #require(JSONSerialization.jsonObject(with: entity.payload) as? [String: Any])
        #expect(payload["body"] as? String == "Build 173")

        snapshot["notifications"] = [
            ["id": "notice-duplicate", "body": "first"],
            ["id": "notice-duplicate", "body": "second"],
        ]
        let duplicateState = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        #expect(duplicateState.entity(kind: "notification", id: "notice-duplicate") == nil)
    }

    @Test func legacySnapshotRemainsReadableButIsSnapshotOnly() throws {
        var snapshot = Self.sessionSnapshot
        snapshot.removeValue(forKey: "cursor")
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))

        #expect(state.cursor == nil)
        #expect(state.syncMode == .snapshotOnly)
        #expect(state.workspaces.map(\.id) == ["ws_api"])
        #expect(CmuxTuiSnapshotParser.resources(from: state).contains { $0.id.key == "term_build" })

        var malformed = snapshot
        malformed["cursor"] = ["generation": "daemon-a", "revision": "not-a-number"]
        #expect(CmuxTuiSnapshotParser.state(fromSnapshot: malformed, machine: Self.machine) == nil)
    }

    @Test func cloudStateIndexIsDerivedAndRebuiltAfterCoding() throws {
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: Self.sessionSnapshot, machine: Self.machine))
        let encoded = try JSONEncoder().encode(state)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["lookupIndex"] == nil)
        #expect(object["document"] != nil)
        #expect(object["rawSnapshot"] == nil)

        let decoded = try JSONDecoder().decode(CloudVMState.self, from: encoded)
        #expect(decoded == state)
        #expect(decoded.lookupIndex.tab(id: "tab_1")?.contentID == "term_build")
        #expect(decoded.lookupIndex.screenIDs(workspaceID: "ws_main") == ["screen_1"])

        // A pre-document archive remains readable through the one-way raw
        // snapshot migration path. Its conflicting typed projections are not
        // trusted.
        var legacyObject = object
        legacyObject.removeValue(forKey: "document")
        legacyObject["rawSnapshot"] = state.rawSnapshot.base64EncodedString()
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(CloudVMState.self, from: legacyData)
        #expect(legacyDecoded == state)
    }

    @Test func legacyAgentDeltaUsesTerminalRelationshipIdentity() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["cursor"] = ["generation": "daemon-a", "revision": "7"]
        snapshot["agents"] = [["terminal_id": "term_build", "state": "working"]]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        let upsert: [String: Any] = [
            "kind": "delta",
            "changes": [[
                "kind": "upsert",
                "resource": "agent",
                "value": ["terminal_id": "term_build", "state": "waiting"],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: upsert)
        let next = try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: data,
            cursor: CloudVMCursor(generation: "daemon-a", revision: 8),
            to: state
        ))
        #expect(next.agents == [CloudVMAgentState(id: nil, terminalID: "term_build", state: "waiting", source: nil)])

        // An explicit id moving to a different terminal cannot be matched to the
        // old id-less row. Appending it would leave a stale agent badge, so the
        // parser must force a full snapshot instead.
        let reassignment: [String: Any] = [
            "kind": "delta",
            "changes": [[
                "kind": "upsert",
                "resource": "agent",
                "id": "agent_new",
                "value": ["id": "agent_new", "terminal_id": "term_shell", "state": "working"],
            ]],
        ]
        let reassignmentData = try JSONSerialization.data(withJSONObject: reassignment)
        #expect(CmuxTuiSnapshotParser.applying(
            deltaPayload: reassignmentData,
            cursor: CloudVMCursor(generation: "daemon-a", revision: 8),
            to: state
        ) == nil)

        // An explicit id cannot claim a relationship already owned by another
        // explicit row. The canonical fragment key must stay aligned with the
        // payload identity, so this also forces a snapshot.
        var explicitSnapshot = Self.sessionSnapshot
        explicitSnapshot["cursor"] = ["generation": "daemon-a", "revision": "7"]
        explicitSnapshot["agents"] = [["id": "agent_old", "terminal_id": "term_build", "state": "working"]]
        let explicitState = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: explicitSnapshot, machine: Self.machine))
        let explicitChange: [String: Any] = [
            "kind": "delta",
            "changes": [[
                "kind": "upsert",
                "resource": "agent",
                "id": "agent_new",
                "value": ["id": "agent_new", "terminal_id": "term_build", "state": "blocked"],
            ]],
        ]
        let explicitData = try JSONSerialization.data(withJSONObject: explicitChange)
        #expect(CmuxTuiSnapshotParser.applying(
            deltaPayload: explicitData,
            cursor: CloudVMCursor(generation: "daemon-a", revision: 8),
            to: explicitState
        ) == nil)
    }

    @Test func deltaRejectsEnvelopeAndSequenceMismatches() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["cursor"] = ["generation": "daemon-a", "revision": "7"]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        let baseChange: [String: Any] = [
            "kind": "upsert",
            "resource": "tab",
            "id": "tab_1",
            "value": [
                "id": "tab_1", "pane_id": "pane_1", "content_kind": "terminal",
                "content_id": "term_build", "name": "renamed",
            ],
        ]
        func data(_ change: [String: Any], revision: Any = "8") throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "kind": "delta",
                "cursor": ["generation": "daemon-a", "revision": revision],
                "previous_revision": "7",
                "revision": revision,
                "changes": [change],
            ])
        }

        var mismatchedEnvelope = baseChange
        mismatchedEnvelope["sequence"] = 0
        #expect(CmuxTuiSnapshotParser.applying(
            deltaPayload: try data(mismatchedEnvelope, revision: "9"),
            cursor: CloudVMCursor(generation: "daemon-a", revision: 8),
            to: state
        ) == nil)

        var badSequence = baseChange
        badSequence["sequence"] = 1
        #expect(CmuxTuiSnapshotParser.applying(
            deltaPayload: try data(badSequence),
            cursor: CloudVMCursor(generation: "daemon-a", revision: 8),
            to: state
        ) == nil)
    }

    @Test func stateSyncRejectsGapsAndOpaqueGenerationOrdering() {
        let current = CloudVMCursor(generation: "daemon-a", revision: 7)
        #expect(CloudVMStateSyncDecision.forSnapshot(incoming: CloudVMCursor(generation: "daemon-a", revision: 6), current: current) == .ignoreStale)
        #expect(CloudVMStateSyncDecision.forSnapshot(incoming: CloudVMCursor(generation: "daemon-b", revision: 1), current: current) == .installSnapshot)
        #expect(CloudVMStateSyncDecision.forDelta(generation: "daemon-a", previousRevision: 6, revision: 8, current: current) == .fetchSnapshot)
        #expect(CloudVMStateSyncDecision.forDelta(generation: "daemon-a", previousRevision: 7, revision: 8, current: current) == .installSnapshot)
        #expect(CloudVMStateSyncDecision.forDelta(generation: "daemon-a", previousRevision: 7, revision: 9, current: current) == .fetchSnapshot)
        #expect(CloudVMStateSyncDecision.forDelta(generation: "daemon-b", previousRevision: 7, revision: 8, current: current) == .fetchSnapshot)
        #expect(CloudVMStateSyncDecision.forSnapshot(incoming: nil, current: nil) == .installSnapshot)
        #expect(CloudVMStateSyncDecision.forSnapshot(incoming: nil, current: current) == .ignoreStale)
    }

    @Test func remoteMutationAuthorityRejectsStaleGraphsAndScopesReceipts() {
        #expect(
            CloudVMRemoteMutationAuthority.resolve(
                refreshEstablishedCurrentGraph: true,
                hasAcceptedState: true,
                targetVisible: true,
                hasVersionedCursor: true,
                hasPendingReceipt: false
            ) == .currentGraph
        )
        #expect(
            CloudVMRemoteMutationAuthority.resolve(
                refreshEstablishedCurrentGraph: true,
                hasAcceptedState: true,
                targetVisible: false,
                hasVersionedCursor: true,
                hasPendingReceipt: true
            ) == .pendingReceipt
        )
        // A receipt has only a revision. Without a successful current refresh
        // its generation is unknown, so it cannot authorize a write.
        #expect(
            CloudVMRemoteMutationAuthority.resolve(
                refreshEstablishedCurrentGraph: false,
                hasAcceptedState: true,
                targetVisible: false,
                hasVersionedCursor: true,
                hasPendingReceipt: true
            ) == .unavailable
        )
        #expect(
            CloudVMRemoteMutationAuthority.resolve(
                refreshEstablishedCurrentGraph: true,
                hasAcceptedState: true,
                targetVisible: true,
                hasVersionedCursor: false,
                hasPendingReceipt: true
            ) == .snapshotOnly
        )
        #expect(
            CloudVMRemoteMutationAuthority.resolve(
                refreshEstablishedCurrentGraph: true,
                hasAcceptedState: true,
                targetVisible: false,
                hasVersionedCursor: true,
                hasPendingReceipt: false
            ) == .targetMissing
        )
    }

    @Test func remoteMutationReceiptsFenceDelayedGraphs() {
        let receipt = CloudVMCursor(generation: "daemon-a", revision: 8)
        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: CloudVMCursor(generation: "daemon-a", revision: 7),
                targetMatches: false
            ) == .rejectStale
        )
        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: CloudVMCursor(generation: "daemon-a", revision: 8),
                targetMatches: false
            ) == .rejectConflict
        )
        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: CloudVMCursor(generation: "daemon-a", revision: 8),
                targetMatches: true
            ) == .accept
        )
        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: CloudVMCursor(generation: "daemon-a", revision: 9),
                targetMatches: false
            ) == .accept
        )
        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: nil,
                targetMatches: true
            ) == .rejectStale
        )
        #expect(
            CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: receipt,
                incoming: CloudVMCursor(generation: "daemon-b", revision: 1),
                targetMatches: false
            ) == .accept
        )
    }

    @Test func repeatedDaemonGenerationIsRecognizedAsAnOldLink() {
        let accepted = Set(["daemon-a", "daemon-b"])
        #expect(
            CloudVMGenerationAcceptanceDecision.resolve(
                incoming: "daemon-a",
                current: "daemon-b",
                accepted: accepted
            ) == .rejectStale
        )
        #expect(
            CloudVMGenerationAcceptanceDecision.resolve(
                incoming: "daemon-c",
                current: "daemon-b",
                accepted: accepted
            ) == .accept
        )
        #expect(
            CloudVMGenerationAcceptanceDecision.resolve(
                incoming: "daemon-b",
                current: "daemon-b",
                accepted: accepted
            ) == .accept
        )
    }

    @Test func snapshotClearsEventWarningOnlyAfterLiveFeedResumes() {
        let cursor = CloudVMCursor(generation: "daemon-a", revision: 7)
        #expect(!CloudVMEventFeedRecoveryDecision.shouldClearWarning(
            snapshotCursor: nil,
            subscriptionResumed: false
        ))
        #expect(!CloudVMEventFeedRecoveryDecision.shouldClearWarning(
            snapshotCursor: cursor,
            subscriptionResumed: false
        ))
        #expect(CloudVMEventFeedRecoveryDecision.shouldClearWarning(
            snapshotCursor: cursor,
            subscriptionResumed: true
        ))
    }

    @Test func eventRecoveryUsesPositiveCappedBackoff() {
        let policy = CloudMachineLinkEventsRecoveryPolicy.standard
        #expect(policy.delay(forAttempt: 1) == .milliseconds(250))
        #expect(policy.delay(forAttempt: 5) == .seconds(4))
        #expect(policy.delay(forAttempt: 6) == nil)
        #expect(policy.stabilityWindow == .seconds(10))
        #expect(policy.delays.allSatisfy { $0 > .zero })
    }

    @Test func eventRecoveryRestartCannotBypassTheBudget() {
        #expect(CloudMachineLink.canRestartEventsSubscription(for: .healthy))
        #expect(CloudMachineLink.canRestartEventsSubscription(for: .recovering(attempt: 3)))
        #expect(CloudMachineLink.canRestartEventsSubscription(for: .snapshotRecovery))
        #expect(!CloudMachineLink.canRestartEventsSubscription(for: .exhausted(canResumeFromSnapshot: true)))
        #expect(!CloudMachineLink.canRestartEventsSubscription(for: .exhausted(canResumeFromSnapshot: false)))
        #expect(!CloudMachineLink.canRestartEventsSubscription(for: .snapshotOnly))
    }

    @Test func cloudTreeRecognizesLegacyWorkspaceProjectionWithoutTabID() throws {
        let machine = SurfaceMachineID.cloud("legacy-placement")
        let workspace = SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true)
        let view = SurfaceRemoteView(tabID: "tab_shell", workspace: workspace)
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_shell"),
            title: "shell",
            detail: "/root",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: workspace,
            remoteViews: [view],
            port: nil,
            url: nil
        )
        let localWorkspaceID = UUID()
        let snapshot = SurfaceCatalogSnapshot(
            machines: [SurfaceMachineInfo(
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
                diskUsedMb: nil,
                remoteWorkspaces: [workspace],
                privateAddress: nil
            )],
            resources: [resource],
            // This is the pre-tab-id archive shape. The single current view is
            // enough to recover its exact tab identity without guessing.
            projections: [SurfaceProjection(
                resource: resource.id,
                workspaceID: localWorkspaceID,
                panelID: UUID(),
                remoteWorkspaceID: workspace.id
            )]
        )

        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [],
            snapshot: snapshot,
            localWorkspaces: [],
            includeLocalMachine: false
        )
        let flattened = CloudTreeNodeBuilder.flattened(nodes)
        let workspaceNode = try #require(flattened.first { $0.id == "machine:legacy-placement/ws/ws_main" })
        if case .workspace(_, _, _, let openIn) = workspaceNode.kind {
            #expect(openIn == localWorkspaceID)
        } else {
            Issue.record("expected the legacy workspace row")
        }
        let terminalNode = try #require(flattened.first {
            $0.id == "machine:legacy-placement/ws/ws_main/resource:legacy-placement/terminal/term_shell/tab:tab_shell"
        })
        if case .terminal(let row) = terminalNode.kind {
            #expect(row.isOpen)
        } else {
            Issue.record("expected the legacy terminal pointer row")
        }
    }

    @Test func cloudTreeRecognizesPrePlacementProjectionWithoutRemoteIDs() throws {
        let machine = SurfaceMachineID.cloud("pre-placement")
        let workspace = SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true)
        let view = SurfaceRemoteView(tabID: "tab_shell", workspace: workspace)
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_shell"),
            title: "shell",
            detail: "/root",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: workspace,
            remoteViews: [view],
            port: nil,
            url: nil
        )
        let localWorkspaceID = UUID()
        let snapshot = SurfaceCatalogSnapshot(
            machines: [SurfaceMachineInfo(
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
                diskUsedMb: nil,
                remoteWorkspaces: [workspace],
                privateAddress: nil
            )],
            resources: [resource],
            // This is the oldest archive shape. It has no remote placement
            // coordinates, so the one-projection/one-view rule must preserve
            // the existing local pane without inventing a tab.
            projections: [SurfaceProjection(
                resource: resource.id,
                workspaceID: localWorkspaceID,
                panelID: UUID()
            )]
        )

        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [],
            snapshot: snapshot,
            localWorkspaces: [],
            includeLocalMachine: false
        )
        let flattened = CloudTreeNodeBuilder.flattened(nodes)
        let terminalNode = try #require(flattened.first {
            $0.id == "machine:pre-placement/ws/ws_main/resource:pre-placement/terminal/term_shell/tab:tab_shell"
        })
        if case .terminal(let row) = terminalNode.kind {
            #expect(row.isOpen)
        } else {
            Issue.record("expected the pre-placement terminal pointer row")
        }
    }

    @Test func cursorDecodingRejectsBooleanFractionalAndOverflowNumbers() {
        #expect(CloudVMCursor(wire: ["generation": "g1", "revision": NSNumber(value: true)]) == nil)
        #expect(CloudVMCursor(wire: ["generation": "g1", "revision": NSNumber(value: 1.5)]) == nil)
        #expect(CloudVMCursor(wire: ["generation": "g1", "revision": NSNumber(value: -1)]) == nil)
        #expect(CloudVMCursor(wire: ["generation": "g1", "revision": NSNumber(value: 8)]) == CloudVMCursor(generation: "g1", revision: 8))
        #expect(CloudVMCursor(wire: ["generation": "g1", "revision": " 9 "]) == CloudVMCursor(generation: "g1", revision: 9))
    }

    @Test func staleCloudStateExportLabelsLastKnownDocument() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["cursor"] = ["generation": "g1", "revision": "3"]
        snapshot["pairing_requests"] = [[
            "id": "pairing-1",
            "code": "123456",
            "peer": "agent",
            "access_token": "do-not-export",
        ]]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        let payload = TerminalController.surfaceCloudStatePayload(
            state,
            observation: .stale(reason: "asleep")
        )
        #expect(payload["freshness"] as? String == "stale")
        #expect(payload["stale_reason"] as? String == "asleep")
        #expect((payload["cursor"] as? [String: Any])?["revision"] as? String == "3")
        #expect(payload["sync_mode"] as? String == "journaled")
        let exportedSnapshot = try #require(payload["snapshot"] as? [String: Any])
        let pairing = try #require((exportedSnapshot["pairing_requests"] as? [[String: Any]])?.first)
        #expect(pairing["code"] as? String == "[REDACTED]")
        #expect(pairing["access_token"] as? String == "[REDACTED]")
        let rawPairing = try #require((state.snapshotObject()?["pairing_requests"] as? [[String: Any]])?.first)
        #expect(rawPairing["code"] as? String == "123456")
    }

    @Test func rootDeletionForcesAFullSnapshot() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["cursor"] = ["generation": "g1", "revision": "3"]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: Self.machine))
        let delta: [String: Any] = [
            "kind": "delta",
            "previous_revision": "3",
            "revision": "4",
            "changes": [[
                "kind": "delete",
                "resource": "session",
                "id": "session-1",
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: delta)
        #expect(CmuxTuiSnapshotParser.applying(
            deltaPayload: data,
            cursor: CloudVMCursor(generation: "g1", revision: 4),
            to: state
        ) == nil)
    }

    @Test func eventEnvelopeParsingKeepsCursorAndCanonicalPayload() throws {
        let snapshotLine = #"{"type":"stream_item","cursor":{"generation":"g1","revision":"4"},"item":{"kind":"snapshot","reset_reason":"initial","snapshot":{"workspaces":[]}}}"#
        guard case .snapshot(let cursor, let reason, let payload) = CloudMachineLink.parseChangeLine(snapshotLine) else {
            Issue.record("expected a snapshot event")
            return
        }
        #expect(cursor == CloudVMCursor(generation: "g1", revision: 4))
        #expect(reason == "initial")
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect((object["cursor"] as? [String: Any])?["revision"] as? String == "4")

        let nullCursorSnapshotLine = #"{"type":"stream_item","cursor":{"generation":"g2","revision":"6"},"item":{"kind":"snapshot","snapshot":{"cursor":null,"workspaces":[]}}}"#
        guard case .snapshot(let nullCursorEnvelope, _, let nullCursorPayload) = CloudMachineLink.parseChangeLine(nullCursorSnapshotLine) else {
            Issue.record("a versioned snapshot with a null embedded cursor must remain versioned")
            return
        }
        #expect(nullCursorEnvelope == CloudVMCursor(generation: "g2", revision: 6))
        let nullCursorObject = try #require(JSONSerialization.jsonObject(with: nullCursorPayload) as? [String: Any])
        #expect((nullCursorObject["cursor"] as? [String: Any])?["revision"] as? String == "6")

        let deltaLine = #"{"type":"stream_item","item":{"kind":"delta","cursor":{"generation":"g1","revision":"5"},"previous_revision":"4","revision":"5","changes":[]}}"#
        guard case .delta(let deltaCursor, let previous, let revision, _) = CloudMachineLink.parseChangeLine(deltaLine) else {
            Issue.record("expected a delta event")
            return
        }
        #expect(deltaCursor == CloudVMCursor(generation: "g1", revision: 5))
        #expect(previous == 4)
        #expect(revision == 5)

        guard case .unknown = CloudMachineLink.parseChangeLine(
            #"{"type":"stream_item","item":{"kind":"delta","cursor":{"generation":"g1","revision":true},"previous_revision":"4","revision":"5","changes":[]}}"#
        ) else {
            Issue.record("boolean cursor revision must be a synchronization barrier")
            return
        }

        guard case .streamEnded(let streamReason, let endCursor) = CloudMachineLink.parseChangeLine(#"{"type":"stream_end","reason":"gap","cursor":{"generation":"g1","revision":"5"}}"#) else {
            Issue.record("expected a stream end")
            return
        }
        #expect(streamReason == "gap")
        #expect(endCursor == CloudVMCursor(generation: "g1", revision: 5))
    }

    @Test func placementGroupsRoundTripExactTabAndRejectLegacyAmbiguity() throws {
        let resource = SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_build")
        let view = SurfaceRemoteView(
            tabID: "tab_4",
            workspace: SurfaceRemoteWorkspace(id: "ws_api", name: "api", index: 1, focused: false),
            screenID: "screen_2",
            paneID: "pane_2",
            name: "api shell",
            index: 0,
            focused: true
        )
        let group = SurfaceResourceGroup(
            title: "api",
            placements: [SurfaceResourcePlacement(resource: resource, remoteView: view)],
            remoteWorkspaceID: "ws_api"
        )
        let decoded = try JSONDecoder().decode(SurfaceResourceGroup.self, from: JSONEncoder().encode(group))
        #expect(decoded == group)
        #expect(decoded.placements.first?.remoteTabID == "tab_4")

        let legacy = try JSONDecoder().decode(
            SurfaceResourceGroup.self,
            from: Data(#"{"title":"api","resources":["vivid-newt/terminal/term_build"],"remoteWorkspaceID":"ws_api"}"#.utf8)
        )
        #expect(legacy.placements.first?.remoteTabID == nil)
        #expect(legacy.placements.first?.remoteWorkspaceID == "ws_api")
    }
}

/// Regression coverage for the snapshot row ordering helper. In
/// 0.64.22-nightly.3400956733901 the app trapped (EXC_BREAKPOINT in
/// `orderedSnapshotRows`) the first time a machine reported any workspace,
/// screen, pane, or tab: the helper returned `enumerated().sorted` through a
/// tuple type with reordered labels, which Swift compiles into a runtime array
/// cast that fails for every non-empty array. Empty snapshots never reach the
/// cast, so the crash only appeared once a machine actually connected.
@Suite struct CmuxTuiSnapshotRowOrderingRegressionTests {
    static let machine = SurfaceMachineID.cloud("gentle-ochre-dingo")

    @Test func workspacesFromANonEmptySnapshotSurviveAndFollowTheirIndexes() {
        let snapshot: [String: Any] = [
            "workspaces": [
                ["id": "ws_second", "name": "second", "index": 1, "focused": false],
                ["id": "ws_first", "name": "first", "index": 0, "focused": true],
                ["id": "ws_legacy", "name": "legacy"],
            ],
        ]
        let workspaces = CmuxTuiSnapshotParser.workspaces(fromSnapshot: snapshot)
        #expect(
            workspaces.map(\.id) == ["ws_first", "ws_second", "ws_legacy"],
            "explicit indexes win; a row without one keeps its transport order after them"
        )
        #expect(workspaces.map(\.index) == [0, 1, 2])
        #expect(workspaces.first?.focused == true)
    }

    @Test func terminalProjectionTargetFromANonEmptySnapshotPrefersFocusedRowsThenIndexes() throws {
        let snapshot: [String: Any] = [
            "workspaces": [
                ["id": "ws_bg", "index": 0, "focused": false],
                ["id": "ws_fg", "index": 1, "focused": true],
            ],
            "screens": [
                ["id": "screen_bg", "workspace_id": "ws_bg", "focused": true],
                ["id": "screen_fg_2", "workspace_id": "ws_fg", "index": 1],
                ["id": "screen_fg_1", "workspace_id": "ws_fg", "index": 0],
            ],
            "panes": [
                ["id": "pane_fg_1", "screen_id": "screen_fg_1"],
                ["id": "pane_bg", "screen_id": "screen_bg"],
            ],
            "tabs": [
                ["id": "tab_1", "pane_id": "pane_fg_1", "content_kind": "terminal", "content_id": "term_1"],
            ],
            "terminals": [
                ["id": "term_1", "tab_id": "tab_1", "title": "shell", "lifecycle": "running"],
            ],
            "browsers": [],
            "agents": [],
        ]
        let target = try #require(CmuxTuiSnapshotParser.terminalProjectionTarget(from: snapshot))
        #expect(target.workspaceID == "ws_fg", "the focused workspace wins over a lower index")
        #expect(target.screenID == "screen_fg_1", "within it, the lowest explicit index wins")
        #expect(target.paneID == "pane_fg_1")
        #expect(target.index == 1, "the new tab lands after the pane's existing tab")
    }

    @Test func terminalsFromANonEmptySnapshotOrderTheirViewsByTabIndex() throws {
        let snapshot: [String: Any] = [
            "workspaces": [["id": "ws_main", "name": "main", "focused": true]],
            "screens": [["id": "screen_1", "workspace_id": "ws_main"]],
            "panes": [["id": "pane_1", "screen_id": "screen_1"]],
            "tabs": [
                ["id": "tab_b", "pane_id": "pane_1", "index": 1, "content_kind": "terminal", "content_id": "term_b"],
                ["id": "tab_a", "pane_id": "pane_1", "index": 0, "content_kind": "terminal", "content_id": "term_a"],
            ],
            "terminals": [
                ["id": "term_b", "tab_id": "tab_b", "title": "b", "lifecycle": "running"],
                ["id": "term_a", "tab_id": "tab_a", "title": "a", "lifecycle": "running"],
            ],
        ]
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: snapshot, machine: Self.machine)
        #expect(resources.map { $0.id.key } == ["term_a", "term_b"], "tab index, not transport order, decides the view order")
        #expect(resources.compactMap { $0.remoteViews?.first?.index } == [0, 1])
    }
}
