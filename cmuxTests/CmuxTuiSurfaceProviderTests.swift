import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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

    @Test func userTabNameLabelsTheTerminalOverItsPtyTitle() throws {
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
        // which the daemon persists and broadcasts; it beats the PTY-derived title.
        let build = try #require(resources.first { $0.id.key == "term_build" })
        #expect(build.title == "build loop")

        // An empty or absent name keeps the PTY title.
        let shell = try #require(resources.first { $0.id.key == "term_shell" })
        #expect(shell.title == "bash")
        #expect(CmuxTuiSnapshotParser.tabNames(fromSnapshot: snapshot) == ["tab_1": "build loop"])
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

        var duplicate = resource
        duplicate["remote_views"] = [
            ["tab_id": "tab_a", "workspace": ["id": "ws_main"], "focused": false],
            ["tab_id": "tab_b", "workspace": ["id": "ws_main"], "focused": false],
        ]
        #expect(CMUXCLI.resolveVMRemoteTerminalPlacement("term_build", machine: "vivid-newt", workspaceID: "ws_main", in: ["resources": [duplicate]]) == .ambiguous)

        #expect(CMUXCLI.resolveVMRemoteTerminalPlacement("term_build", machine: "vivid-newt", workspaceID: "ws_main", in: ["resources": [["kind": "terminal", "key": "term_build", "remote_views": NSNull()]]]) == .unavailable)
    }

    @Test func cloudRenameWriteThroughTargetsAndNames() throws {
        // The persisted binding wins over projections.
        let bound = CloudWorkspaceRenameWriteThrough.remoteTarget(
            binding: WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_main"),
            projectedResources: []
        )
        #expect(bound?.machine == .cloud("vivid-newt"))
        #expect(bound?.remoteWorkspaceID == "ws_main")

        // Without a binding, projections decide only when every view agrees…
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: Self.sessionSnapshot, machine: Self.machine)
        let shell = try #require(resources.first { $0.id.key == "term_shell" })
        #expect(CloudWorkspaceRenameWriteThrough.remoteTarget(binding: nil, projectedResources: [shell])?.remoteWorkspaceID == "ws_api")

        // …a terminal viewed in two remote workspaces, or no panes at all, refuses to guess.
        let build = try #require(resources.first { $0.id.key == "term_build" })
        #expect(CloudWorkspaceRenameWriteThrough.remoteTarget(binding: nil, projectedResources: [build])?.remoteWorkspaceID == nil)
        #expect(CloudWorkspaceRenameWriteThrough.remoteTarget(binding: nil, projectedResources: [])?.remoteWorkspaceID == nil)

        // Legacy projection fallback drops the generated prefix; a bound workspace keeps
        // an intentional prefix as part of the user's exact title.
        #expect(CloudWorkspaceRenameWriteThrough.remoteName(fromLocalTitle: "vivid-newt: api", machine: Self.machine) == "api")
        #expect(CloudWorkspaceRenameWriteThrough.remoteName(fromLocalTitle: "vivid-newt: api", machine: Self.machine, stripGeneratedPrefix: false) == "vivid-newt: api")
        #expect(CloudWorkspaceRenameWriteThrough.remoteName(fromLocalTitle: "api work", machine: Self.machine) == "api work")
        #expect(CloudWorkspaceRenameWriteThrough.remoteName(fromLocalTitle: "   ", machine: Self.machine) == nil)
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
            ["id": "term_one", "tab_ids": ["tab_1", "tab_1"], "title": "one", "lifecycle": "running"],
        ]
        let state = CmuxTuiSnapshotParser.state(fromSnapshot: repeatedReference, machine: Self.machine)
        #expect(state?.terminals.first?.tabIDs == ["tab_1"])
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
        #expect(CloudTuiCommandLine.linkArguments(route: "wss://m.vm.cmux.sh/v1/link?t=1", deviceName: "cmux-mac", stateDir: "/s", inviteFilePath: "/i") ==
            ["remote", "connect", "wss://m.vm.cmux.sh/v1/link?t=1", "--device-name", "cmux-mac", "--state-dir", "/s", "--headless", "--json", "--invite-file", "/i"])
        #expect(CloudTuiCommandLine.linkArguments(route: "r", deviceName: "d", stateDir: "/s", inviteFilePath: nil) ==
            ["remote", "connect", "r", "--device-name", "d", "--state-dir", "/s", "--headless", "--json"])
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
        #expect(CloudTuiCommandLine.renameTabArguments(socketPath: "/k.sock", tabID: "tab_1", name: "db shell", expectedRevision: 9) ==
            ["--socket", "/k.sock", "--json", "--expected-revision", "9", "tab", "tab_1", "rename", "--name", "db shell"])
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

    @Test func portEndpointsAreReusedUntilTheyExpire() {
        var cache = SurfacePortEndpointCache(ttl: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(cache.openURL(port: 6901, now: t0) == nil)
        cache.store(openURL: "https://m-6901.vm.cmux.sh/?bl_preview_token=t1", port: 6901, now: t0)
        #expect(cache.openURL(port: 6901, now: t0.addingTimeInterval(59)) == "https://m-6901.vm.cmux.sh/?bl_preview_token=t1")
        #expect(cache.openURL(port: 3000, now: t0) == nil, "one entry per port")
        #expect(cache.openURL(port: 6901, now: t0.addingTimeInterval(60)) == nil, "gone at ttl")
        cache.store(openURL: "https://m-6901.vm.cmux.sh/?bl_preview_token=t2", port: 6901, now: t0.addingTimeInterval(60))
        #expect(cache.openURL(port: 6901, now: t0.addingTimeInterval(61))?.hasSuffix("t2") == true)
        cache.invalidate(port: 6901)
        #expect(cache.openURL(port: 6901, now: t0.addingTimeInterval(61)) == nil)
        #expect(SurfacePortEndpointCache.defaultTTL < 7 * 24 * 60 * 60, "well inside the preview token's 7-day life")
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
    }

    @Test func revisionedStateRetainsTheWholeRemoteDocumentAndAppliesTabDelta() throws {
        var snapshot = Self.sessionSnapshot
        snapshot["cursor"] = ["generation": "daemon-a", "revision": "7"]
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
        #expect(next.tabs.first { $0.id == "tab_1" }?.name == "renamed")
        let terminal = try #require(CmuxTuiSnapshotParser.resources(from: next).first { $0.id.key == "term_build" })
        #expect(terminal.remoteViews?.first?.name == "renamed")
        #expect(terminal.title == "renamed")
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
    }

    @Test func eventRecoveryUsesPositiveCappedBackoff() {
        let policy = CloudMachineLinkEventsRecoveryPolicy.standard
        #expect(policy.delay(forAttempt: 1) == .milliseconds(250))
        #expect(policy.delay(forAttempt: 5) == .seconds(4))
        #expect(policy.delay(forAttempt: 6) == nil)
        #expect(policy.delays.allSatisfy { $0 > .zero })
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
