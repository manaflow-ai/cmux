import CmuxCloud
import CmuxCloudTui
import CmuxCore
import CmuxFoundation
import CmuxSurfaceCatalogModel
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class SSHHereDaemonFixture {
    enum Mode: String { case normal, failCreate, holdCreate, holdPreflight }
    let app: VaultPaneAppFixture
    let root: URL
    let connection: SSHTuiConnection
    let links: SSHTuiLinkManager
    let provider: CmuxTuiSurfaceProvider
    let caller = Process()
    private(set) var callerIdentity: AgentPIDProcessIdentity?
    var workspace: Workspace { app.workspace }
    var manager: TabManager { app.manager }

    private init(mode: Mode) async throws {
        root = URL(fileURLWithPath: "/tmp/cmux-here-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try mode.rawValue.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let client = root.appendingPathComponent("daemon-fixture")
        try Self.daemonScript.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)
        app = try VaultPaneAppFixture()
        let preflight = root.appendingPathComponent("held-preflight")
        let routeOptions = mode == .holdPreflight
            ? ["ProxyCommand=/bin/sh '\(preflight.path)'", "ControlMaster=no", "ControlPath=none"] : []
        try """
        : > '\(root.appendingPathComponent("preflight-started").path)'
        i=0
        while [ ! -e '\(root.appendingPathComponent("release-preflight").path)' ] && [ "$i" -lt 600 ]; do
          sleep 0.05; i=$((i + 1))
        done
        echo 'ssh: Permission denied (publickey).' >&2
        exit 1
        """.write(to: preflight, atomically: true, encoding: .utf8)
        connection = SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            terminalProfile: .shell, destination: "here-\(UUID().uuidString.lowercased()).invalid",
            port: nil, identityFile: nil, sshOptions: routeOptions, localProxyPort: nil, relayPort: nil,
            relayID: nil, relayToken: nil, localSocketPath: nil, terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        ))
        links = SSHTuiLinkManager(connection: connection, clientURL: client,
                                  paths: CloudTuiClientPaths(home: root), isEnabled: { true })
        provider = CmuxTuiSurfaceProvider(summary: .ssh(connection), links: links, catalog: .shared)
        // Preconnect the real link to the local peer. The open handler then
        // finds this exact connection instead of doing authentication/network
        // I/O. Production graph/create/materialize/cancel paths remain intact.
        do {
            caller.executableURL = URL(fileURLWithPath: "/bin/sleep")
            caller.arguments = ["120"]
            caller.standardInput = FileHandle.nullDevice
            caller.standardOutput = FileHandle.nullDevice
            caller.standardError = FileHandle.nullDevice
            try caller.run()
            callerIdentity = try #require(AgentPIDProcessIdentity(pid: caller.processIdentifier))
            _ = try #require(manager.createWorkspaceGroup(name: "Keep this group", childWorkspaceIds: [workspace.id]))
            manager.setCustomTitle(tabId: workspace.id, title: "Local before SSH")
            if mode != .holdPreflight {
                try await startCarrier()
                let link = try #require(await links.link(machineID: connection.id))
                var changes = link.changes.makeAsyncIterator()
                #expect(await changes.next() == .connected)
            }
            SurfaceCatalog.shared.register(provider)
        } catch {
            try? await stopCaller()
            await links.disconnect()
            app.tearDown()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    static func withFixture(
        mode: Mode = .normal,
        body: (SSHHereDaemonFixture) async throws -> Void
    ) async throws {
        let fixture = try await SSHHereDaemonFixture(mode: mode)
        do {
            try await body(fixture)
            await fixture.tearDown()
        } catch {
            await fixture.tearDown()
            throw error
        }
    }

    func open(extra: [String: Any] = [:], includeCaller: Bool = true) async throws -> [String: Any] {
        let panel = try #require(workspace.focusedPanelId)
        var params: [String: Any] = [
            "here": true, "workspace_id": workspace.id.uuidString, "surface_id": panel.uuidString,
            "destination": connection.configuration.destination, "terminal_profile": "shell",
            "ssh_options": connection.configuration.sshOptions,
            "operation_id": UUID().uuidString, "focus": false,
            "initial_command": "printf remote-only",
        ]
        if includeCaller { params["caller_process"] = try callerProcessPayload() }
        params.merge(extra) { _, value in value }
        return try await TerminalController.shared.openSSHTuiWorkspace(params: params)
    }

    func callerProcessPayload() throws -> [String: Any] {
        let identity = try #require(callerIdentity)
        return ["pid": Int(identity.pid), "start_seconds": identity.startSeconds,
                "start_microseconds": identity.startMicroseconds]
    }

    func startCarrier() async throws { _ = try await links.connected(machineID: connection.id) }

    func stopCaller() async throws {
        guard caller.isRunning else { return }
        caller.terminate()
        let deadline = ContinuousClock.now + .seconds(2)
        while caller.isRunning, ContinuousClock.now < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if caller.isRunning { Darwin.kill(caller.processIdentifier, SIGKILL) }
        caller.waitUntilExit()
    }

    func operations() throws -> [String] {
        let url = root.appendingPathComponent("requests.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
            let object = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            return (object?["operation"] ?? object?["cmd"]) as? String
        }
    }

    func waitForCreate() async throws {
        try await waitForMarker("create-started")
    }

    func waitForPreflight() async throws { try await waitForMarker("preflight-started") }

    private func waitForMarker(_ name: String) async throws {
        let marker = root.appendingPathComponent(name)
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: marker.path), "The real request must reach \(name)")
    }

    func releaseCreate() throws { try Data().write(to: root.appendingPathComponent("release-create")) }
    func releasePreflight() throws { try Data().write(to: root.appendingPathComponent("release-preflight")) }

    /// A real CLI request enters the production async handler, while socket
    /// EOF deliberately does not cancel that handler. This reproduces the
    /// disconnect race rather than substituting test-side Task cancellation.
    func interruptCLIWhilePreflightIsHeld() async throws {
        typealias Harness = SSHStartupManualReconnectTests
        let executable = try BundledCLITestSupport.bundledCLIPath(for: SSHHereDaemonFixture.self)
        let socketPath = Harness.makeSocketPath("here-interrupt")
        let listener = try Harness.bindUnixSocket(at: socketPath)
        let state = SSHHereOpenAdapterState()
        let eof = CloudLinkFirstValue<Bool>()
        let process = Process()
        defer {
            try? releasePreflight()
            state.openTask?.cancel()
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listener)
            Darwin.close(listener)
            unlink(socketPath)
        }
        CLIMockAcceptLoopRegistry.shared.start(listenerFD: listener, onConnection: { client in
            defer { Darwin.close(client); eof.resolve(true) }
            cliMockServeLineFramedConnection(clientFD: client) { line in
                Task { @MainActor in
                    guard state.openTask == nil else { Issue.record("Unexpected second CLI open"); return }
                    state.openTask = Task { @MainActor in
                        defer { state.finished = true }
                        do {
                            let request = try #require(Harness.jsonObject(line))
                            #expect(request["method"] as? String == "workspace.ssh.open")
                            let params = try #require(request["params"] as? [String: Any])
                            #expect(params["here"] as? Bool == true)
                            let caller = params["caller_process"] as? [String: Any]
                            #expect(caller?["pid"] as? Int == state.expectedPID)
                            _ = try await TerminalController.shared.openSSHTuiWorkspace(params: params)
                            state.completed.resolve(true)
                        } catch {
                            state.completed.resolve(false)
                        }
                    }
                }
                // Continue reading until the real CLI closes the descriptor.
                // No response is needed: the test interrupts this request while
                // preflight is held, before an answer exists.
                return nil
            }
        }, onListenerClosed: {})
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspace.id.uuidString
        environment["CMUX_SURFACE_ID"] = try #require(workspace.focusedPanelId).uuidString
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = root.path
        environment["CFFIXED_USER_HOME"] = root.path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
        environment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        var arguments = ["--json", "ssh", "--here", "--no-focus", connection.configuration.destination]
        for option in connection.configuration.sshOptions { arguments += ["--ssh-option", option] }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        state.expectedPID = Int(process.processIdentifier)
        try await waitForPreflight()
        try #require(process.isRunning, "The bundled CLI must still be waiting on the app")
        try #require(Darwin.kill(process.processIdentifier, SIGINT) == 0)
        let exitDeadline = ContinuousClock.now + .seconds(3)
        while process.isRunning, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!process.isRunning, "SIGINT must actually terminate the bundled CLI")
        process.waitUntilExit()
        #expect(process.terminationStatus == SIGINT || process.terminationStatus == 130)
        #expect(await eof.result == true, "The adapter must observe the interrupted client's real EOF")
        #expect(state.openTask != nil)
        #expect(state.openTask?.isCancelled == false, "Client EOF must leave the server operation alive")
        #expect(!state.finished, "The preflight is still held after the CLI has exited")
        // This carrier makes the pending preflight's eventual refusal harmless.
        // Only live-caller validation can prevent the subsequent pane handoff.
        try await startCarrier()
        try releasePreflight()
        #expect(await state.completed.result == false, "An interrupted CLI must not open a remote pane later")
    }

    private func tearDown() async {
        try? releaseCreate()
        try? releasePreflight()
        try? await stopCaller()
        // Include a workspace erroneously created by the pre-fix handler, so
        // a red assertion does not leak app state into the next test.
        for workspace in manager.tabs {
            workspace.disconnectRemoteConnection(clearConfiguration: true)
            workspace.teardownAllPanels()
        }
        SurfaceCatalog.shared.unregister(machine: provider.machine)
        await links.disconnect()
        await provider.stop()
        app.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    /// A daemon peer, started/reaped by CloudMachineLink. Its two connections
    /// serve the production control client and native byte attachment. The
    /// hold marker is a deterministic create barrier, not a timing-based mock.
    static let daemonScript = #"""
    #!/usr/bin/python3
    import copy
    import json
    import pathlib
    import socket
    import threading
    import time

    root = pathlib.Path(__file__).parent
    mode = (root / "mode").read_text()
    path = str(root / "daemon.sock")
    terminal = "term_" + "1" * 32
    state = {"cursor": {"generation": "here-daemon", "revision": "1"},
             "workspaces": [], "screens": [], "panes": [], "tabs": [],
             "terminals": [], "browsers": [], "agents": []}
    lock = threading.Lock()

    def advance():
        state["cursor"]["revision"] = str(int(state["cursor"]["revision"]) + 1)

    def receipt(value):
        return {"value": value, "cursor": copy.deepcopy(state["cursor"])}

    def serve(peer):
        with peer, peer.makefile("r") as reader:
            for line in reader:
                request = json.loads(line)
                op = request.get("operation", request.get("cmd"))
                params = request.get("params", request)
                with lock, (root / "requests.jsonl").open("a") as log:
                    log.write(line)
                if op == "workspace.run":
                    (root / "create-started").touch()
                    deadline = time.monotonic() + 30
                    while mode == "holdCreate" and not (root / "release-create").exists():
                        if time.monotonic() > deadline:
                            raise AssertionError("create barrier was never released")
                        time.sleep(0.01)
                response = {"id": request["id"], "ok": True}
                if "operation" in request:
                    response.update(protocol="cmux.protocol/2", type="response")
                with lock:
                    if op == "session.snapshot":
                        result = copy.deepcopy(state)
                    elif op == "session.events":
                        result = {"stream_id": params["stream_id"]}
                    elif op == "workspace.create":
                        assert params["initial_content"] == "empty"
                        state["workspaces"] = [{"id": "ws_here", "name": "remote", "focused": True}]
                        state["screens"] = [{"id": "screen_here", "workspace_id": "ws_here"}]
                        state["panes"] = [{"id": "pane_here", "screen_id": "screen_here"}]
                        advance()
                        result = receipt({"workspace_id": "ws_here"})
                    elif op == "workspace.run" and mode == "failCreate":
                        response.update(ok=False, error={"code": "create_refused", "message": "Fixture refused terminal creation"})
                        result = {}
                    elif op == "workspace.run":
                        assert params["workspace"] == "ws_here"
                        state["tabs"] = [{"id": "tab_here", "pane_id": "pane_here", "content_kind": "terminal", "content_id": terminal}]
                        state["terminals"] = [{"id": terminal, "title": "remote", "cwd": "/remote/project", "lifecycle": "running"}]
                        advance()
                        result = receipt({"workspace_id": "ws_here", "screen_id": "screen_here",
                                          "pane_id": "pane_here", "tab_id": "tab_here", "terminal_id": terminal})
                    elif op == "workspace.rename":
                        assert params["workspace"] == "ws_here"
                        state["workspaces"][0]["name"] = params["name"]
                        advance()
                        result = receipt({})
                    elif op == "identify":
                        result = {"protocol": 9, "capabilities": ["terminal-pending-sequence-v1"]}
                    elif op == "resolve-terminal":
                        result = {"surface": 1, "lifecycle": "running"}
                    elif op == "machine-listening-tcp":
                        result = {"ports": []}
                    elif op in ("request.cancel", "stream.cancel", "set-client-info", "attach-surface",
                                "detach-surface", "ping", "session.terminal_defaults.update", "url-open-subscribe"):
                        result = {}
                    else:
                        raise AssertionError("Unexpected daemon operation: " + str(op))
                response["result" if "operation" in request else "data"] = result
                try:
                    peer.sendall((json.dumps(response) + "\n").encode())
                except (BrokenPipeError, ConnectionResetError):
                    return

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(8)
    print(json.dumps({"event": "connection-snapshot", "local_socket": path, "connection": {}}), flush=True)
    while True:
        peer, _ = listener.accept()
        threading.Thread(target=serve, args=(peer,), daemon=True).start()
    """#
}

@MainActor
private final class SSHHereOpenAdapterState {
    var expectedPID: Int?
    var openTask: Task<Void, Never>?
    var finished = false
    let completed = CloudLinkFirstValue<Bool>()
}
