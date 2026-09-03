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
        // Verified live: the flat `set-default-colors` verb is `usage.invalid` in the v2
        // resource CLI; the session-scoped form below is the one machines accept.
        #expect(CloudTuiCommandLine.setDefaultColorsArguments(socketPath: "/k.sock", foreground: "#d8dee9", background: "#171b2e") ==
            ["--socket", "/k.sock", "--json", "session", "current", "terminal", "defaults", "set", "--foreground", "#d8dee9", "--background", "#171b2e"])
        #expect(CloudTuiCommandLine.setDefaultColorsArguments(socketPath: "/k.sock", foreground: nil, background: "#171b2e") ==
            ["--socket", "/k.sock", "--json", "session", "current", "terminal", "defaults", "set", "--background", "#171b2e"])
        // No colors, no command: pushing an empty defaults update would be a no-op round trip.
        #expect(CloudTuiCommandLine.setDefaultColorsArguments(socketPath: "/k.sock", foreground: nil, background: nil) == nil)
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
}
