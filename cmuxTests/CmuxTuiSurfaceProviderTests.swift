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
        ],
        "terminals": [
            ["id": "term_build", "tab_id": "tab_1", "tab_ids": ["tab_1"], "title": "cargo test", "cwd": "/root/work/app", "lifecycle": "running", "running": true],
            ["id": "term_shell", "tab_id": "tab_2", "tab_ids": ["tab_2"], "title": "", "lifecycle": "exited", "running": false],
            ["id": "term_orphan", "tab_id": "tab_missing", "tab_ids": [], "title": "orphan", "running": true],
        ],
        "agents": [
            ["id": "agent_1", "terminal_id": "term_build", "state": "working", "source": "claude"],
        ],
    ]

    @Test func snapshotBecomesTerminalResourcesAttributedToWorkspaces() throws {
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: Self.sessionSnapshot, machine: Self.machine)
        #expect(resources.map { $0.id.key } == ["term_build", "term_orphan", "term_shell"])
        #expect(resources.allSatisfy { $0.kind == .terminal && $0.machine == Self.machine })

        let build = try #require(resources.first { $0.id.key == "term_build" })
        #expect(build.title == "cargo test")
        #expect(build.detail == "/root/work/app")
        #expect(build.lifecycle == .running)
        #expect(build.agent == SurfaceAgentBadge(state: "working", source: "claude"))
        #expect(build.remoteWorkspace == SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true))

        // An untitled terminal stays untitled (the row shows a localized fallback, never the raw id).
        let shell = try #require(resources.first { $0.id.key == "term_shell" })
        #expect(shell.title == "")
        #expect(shell.lifecycle == .exited)
        #expect(shell.agent == nil)
        #expect(shell.remoteWorkspace?.id == "ws_api")

        // A terminal whose tab chain does not resolve lands in the first workspace; no lifecycle key → `running` decides.
        let orphan = try #require(resources.first { $0.id.key == "term_orphan" })
        #expect(orphan.remoteWorkspace?.id == "ws_main")
        #expect(orphan.lifecycle == .running)
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
        #expect(CmuxTuiSnapshotParser.machineHasDesktop(image: "blaxel/xfce-vnc:latest"))
        #expect(!CmuxTuiSnapshotParser.machineHasDesktop(image: "blaxel/base-image:latest"))

        let screen = CmuxTuiSnapshotParser.screen(machine: Self.machine)
        #expect(screen.id == SurfaceResourceID(machine: Self.machine, kind: .screen, key: "display:1"))
        #expect(screen.port == 6901)
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
}
