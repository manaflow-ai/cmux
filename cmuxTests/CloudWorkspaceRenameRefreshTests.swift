import CmuxCloud
import CmuxCloudTui
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct CloudWorkspaceRenameRefreshTests {
    /// Exercises the production forced-refresh and rename path against a local daemon.
    @Test("Terminal output at an equal cursor does not block the forced refresh before workspace rename", .timeLimit(.minutes(1)))
    func renameWorkspaceAfterTerminalOutput() async throws {
        let result = try await renameAfterTerminalOutput { catalog, machine in
            try await catalog.renameRemoteWorkspace(on: machine, id: "ws_main", name: "After")
        }
        #expect(result.state.lookupIndex.workspace(id: "ws_main")?.name == "After")
        Self.expectOneFencedRename(result.mutations, operation: "workspace.rename", key: "workspace", id: "ws_main")
    }

    /// The pane title editor and the cloud tree's view row rename one daemon tab.
    @Test("Terminal output at an equal cursor does not block the forced refresh before pane rename", .timeLimit(.minutes(1)))
    func renamePaneAfterTerminalOutput() async throws {
        let result = try await renameAfterTerminalOutput { catalog, machine in
            try await catalog.renameRemoteTab(on: machine, id: "tab", name: "After")
        }
        #expect(result.state.lookupIndex.tab(id: "tab")?.name == "After")
        Self.expectOneFencedRename(result.mutations, operation: "tab.rename", key: "tab", id: "tab")
    }

    /// The cloud tree's terminal row renames every tab that shows the terminal.
    @Test("Terminal output at an equal cursor does not block the forced refresh before terminal rename", .timeLimit(.minutes(1)))
    func renameTerminalAfterTerminalOutput() async throws {
        let result = try await renameAfterTerminalOutput { catalog, machine in
            let terminal = SurfaceResourceID(machine: machine, kind: .terminal, key: "term")
            try await catalog.renameTerminal(on: machine, id: terminal, name: "After")
        }
        #expect(result.state.lookupIndex.tab(id: "tab")?.name == "After")
        Self.expectOneFencedRename(result.mutations, operation: "tab.rename", key: "tab", id: "tab")
    }

    /// Runs one catalog rename against the daemon fixture. Returns the accepted
    /// state and every rename request the daemon received.
    private func renameAfterTerminalOutput(
        _ rename: (SurfaceCatalog, SurfaceMachineID) async throws -> Void
    ) async throws -> (state: CloudVMState, mutations: [[String: Any]]) {
        let root = URL(fileURLWithPath: "/tmp/cmux-rename-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot: [String: Any] = [
            "cursor": ["generation": "daemon", "revision": "7"],
            "workspaces": [["id": "ws_main", "name": "Before"]],
            "screens": [["id": "screen", "workspace_id": "ws_main"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": [["id": "tab", "pane_id": "pane", "name": "Before", "content_kind": "terminal", "content_id": "term"]],
            "terminals": [["id": "term", "title": "bash", "cwd": "/srv/project", "lifecycle": "running", "stream_revision": "1"]],
            "browsers": [], "agents": []
        ]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: root.appendingPathComponent("snapshot.json"))
        let client = root.appendingPathComponent("daemon-fixture")
        try Self.daemonScript.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)

        // SSH hosting bypasses Cloud authentication and stats. The catalog,
        // provider, forced snapshot read, link and rename RPC are all production
        // paths shared with Cloud machines; only the daemon peer is a fixture.
        let connection = SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            terminalProfile: .shell, destination: "rename-fixture.invalid", port: nil, identityFile: nil,
            sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, preserveAfterTerminalExit: true
        ))
        let links = SSHTuiLinkManager(
            connection: connection, clientURL: client,
            paths: CloudTuiClientPaths(home: root), isEnabled: { true }
        )
        _ = try await links.connected(machineID: connection.id)
        let link = try #require(await links.link(machineID: connection.id))
        // Drain the connection edge before the provider subscribes. Otherwise
        // its unrelated initial refresh can race the rename's forced read.
        var changes = link.changes.makeAsyncIterator()
        #expect(await changes.next() == .connected)
        let catalog = SurfaceCatalog()
        let provider = CmuxTuiSurfaceProvider(summary: .ssh(connection), links: links, catalog: catalog)
        catalog.register(provider)
        let initial = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: provider.machine))
        #expect(provider.installSnapshotIfNewer(initial))
        provider.publish(initial, ports: [])

        do {
            // Every rename calls refreshCurrentGraph(force: true) before sending
            // the mutation. The peer changes only stream_revision in that read.
            try await rename(catalog, provider.machine)
            let current = try #require(catalog.cloudStates[provider.machine])
            #expect(current.cursor == CloudVMCursor(generation: "daemon", revision: 8))
            #expect(catalog.cloudStateObservations[provider.machine]?.freshness == .current)
            let terminals = try #require(current.snapshotObject()?["terminals"] as? [[String: Any]])
            #expect(terminals.first?["stream_revision"] as? String == "3")
            let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let mutations = requests.compactMap { $0 }.filter {
                ($0["operation"] as? String)?.hasSuffix(".rename") == true
            }
            catalog.unregister(machine: provider.machine)
            await provider.stop()
            await links.disconnect()
            return (current, mutations)
        } catch {
            catalog.unregister(machine: provider.machine)
            await provider.stop()
            await links.disconnect()
            throw error
        }
    }

    private static func expectOneFencedRename(
        _ mutations: [[String: Any]],
        operation: String,
        key: String,
        id: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(mutations.count == 1, sourceLocation: sourceLocation)
        #expect(mutations.first?["operation"] as? String == operation, sourceLocation: sourceLocation)
        let params = mutations.first?["params"] as? [String: Any]
        #expect(params?[key] as? String == id, sourceLocation: sourceLocation)
        #expect(params?["name"] as? String == "After", sourceLocation: sourceLocation)
        #expect(params?["expected_revision"] as? String == "7", sourceLocation: sourceLocation)
    }

    // A local protocol peer, started and reaped by the real CloudMachineLink.
    // It keeps the event feed idle so no newer event can hide a rejected read.
    private static let daemonScript = #"""
    #!/usr/bin/python3
    import json
    import pathlib
    import socket

    root = pathlib.Path(__file__).parent
    path = str(root / "daemon.sock")
    snapshot = json.loads((root / "snapshot.json").read_text())
    targets = {"workspace.rename": ("workspace", "workspaces", "ws_main"), "tab.rename": ("tab", "tabs", "tab")}
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(1)
    print(json.dumps({"event": "connection-snapshot", "local_socket": path, "connection": {}}), flush=True)
    peer, _ = listener.accept()
    with peer, peer.makefile("r") as reader, (root / "requests.jsonl").open("w") as log:
        for line in reader:
            request = json.loads(line)
            log.write(line)
            log.flush()
            op = request.get("operation", request.get("cmd"))
            params = request.get("params", {})
            response = {"id": request["id"], "ok": True}
            if "operation" in request:
                response.update(protocol="cmux.protocol/2", type="response")
            if op == "session.events":
                result = {"stream_id": params["stream_id"]}
            elif op == "session.snapshot":
                terminal = snapshot["terminals"][0]
                terminal["stream_revision"] = str(int(terminal["stream_revision"]) + 1)
                result = snapshot
            elif op in targets:
                key, collection, target = targets[op]
                assert params[key] == target
                assert params["expected_revision"] == snapshot["cursor"]["revision"]
                snapshot[collection][0]["name"] = params["name"]
                snapshot["cursor"]["revision"] = str(int(snapshot["cursor"]["revision"]) + 1)
                result = {"cursor": snapshot["cursor"]}
            elif op == "machine-listening-tcp":
                result = {"ports": []}
            elif op in ("stream.cancel", "request.cancel"):
                result = {}
            else:
                raise AssertionError("unexpected request: " + op)
            response["result" if "operation" in request else "data"] = result
            peer.sendall((json.dumps(response) + "\n").encode())
    """#
}
