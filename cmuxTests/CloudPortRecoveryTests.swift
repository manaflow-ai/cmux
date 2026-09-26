import CmuxCloud
import CmuxCloudBannerCore
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
@Suite("Cloud port recovery", .timeLimit(.minutes(1)))
struct CloudPortRecoveryTests {
    @Test("Retry reads one machine's metadata and installs its current private route")
    func refreshMissingAddress() async throws {
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        var requested: [String] = []
        let provider = CmuxTuiSurfaceProvider(summary: summary(), links: links, catalog: catalog,
            loadPortSummary: { id in
                requested.append(id)
                return summary(address: "10.0.0.7")
            })
        catalog.register(provider)
        #expect(provider.info.portDiscoveryState == .unavailable(.privateAddress))
        try await provider.refreshPortMetadata()
        #expect(requested == ["port-owner"])
        #expect(provider.info.privateAddress == "10.0.0.7")
        #expect(await links.privateAddresses(for: "port-owner") == ["10.0.0.7"])
        await provider.stop()
    }

    @Test("An explicit catalog refresh opts into demand-driven port discovery")
    func explicitRefreshRequestsDiscovery() async {
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        let provider = CmuxTuiSurfaceProvider(
            summary: summary(address: "10.0.0.7"), links: links, catalog: catalog
        )
        catalog.register(provider)
        #expect(!provider.portDiscovery.mayScan)
        await catalog.refresh(machine: .cloud("port-owner"), force: true)
        #expect(provider.portDiscovery.mayScan)
        await provider.stop()
    }

    @Test("An SSH machine's loopback route admits demand-driven discovery")
    func sshLoopbackRouteAdmitsDiscovery() async {
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        let provider = CmuxTuiSurfaceProvider(summary: .ssh(sshConnection()), links: links, catalog: catalog)
        catalog.register(provider)
        #expect(provider.info.privateAddress == "127.0.0.1")
        #expect(provider.info.portDiscoveryState == .notRequested)
        provider.requestPortDiscovery()
        #expect(provider.portDiscovery.mayScan)
        #expect(provider.info.portDiscoveryState == .loading)
        await provider.stop()
    }

    @Test("A requested scan settles when the machine's link cannot connect")
    func failedLinkSettlesDiscovery() async {
        let catalog = SurfaceCatalog()
        let provider = CmuxTuiSurfaceProvider(summary: .ssh(sshConnection()), links: UnreachableLinks(), catalog: catalog)
        catalog.register(provider)
        provider.requestPortDiscovery()
        #expect(provider.info.portDiscoveryState == .loading)
        await provider.refreshCurrentGraph(force: true)
        #expect(provider.info.portDiscoveryState == .unavailable(.link))
        await provider.stop()
    }

    /// The cached pass retires the rescan's refresh, but the rescan still owns the Ports request.
    @Test("A rescan's inventory publishes its rows after a cached refresh retires its pass")
    func rescanRowsSurviveCachedRefresh() async throws {
        try await withPortsFixture { root, provider, catalog in
            provider.requestPortDiscovery()
            await provider.refreshCurrentGraph(force: true)
            #expect(await eventually { Self.portRows(catalog, provider.machine) == [3000] })
            // The daemon holds the second scan until the cached pass has landed.
            await provider.refreshCurrentGraph(force: true)
            #expect(await eventually { Self.fixtureFileExists(root, "scan-started") })
            await provider.refreshCurrentGraph(force: false)
            #expect(provider.info.portDiscoveryState == .available)
            #expect(Self.portRows(catalog, provider.machine) == [3000])
            Self.createFixtureFile(root, "release-scan")
            #expect(await eventually { Self.portRows(catalog, provider.machine) == [3000, 8000] })
            #expect(provider.info.portDiscoveryState == .available)
        }
    }

    /// A pass captures the inventory before its snapshot read; a rescan can land during that read.
    @Test("A snapshot that lands after a rescan does not restore the previous Ports rows")
    func lateSnapshotKeepsRescanRows() async throws {
        try await withPortsFixture { root, provider, catalog in
            provider.requestPortDiscovery()
            await provider.refreshCurrentGraph(force: true)
            #expect(await eventually { Self.portRows(catalog, provider.machine) == [3000] })
            await provider.refreshCurrentGraph(force: true)
            #expect(await eventually { Self.fixtureFileExists(root, "scan-started") })
            Self.createFixtureFile(root, "hold-snapshot")
            let cached = Task { await provider.refreshCurrentGraph(force: false) }
            #expect(await eventually { Self.fixtureFileExists(root, "snapshot-started") })
            Self.createFixtureFile(root, "release-scan")
            #expect(await eventually { Self.portRows(catalog, provider.machine) == [3000, 8000] })
            Self.createFixtureFile(root, "release-snapshot")
            _ = await cached.value
            #expect(Self.portRows(catalog, provider.machine) == [3000, 8000])
        }
    }

    @Test("A metadata result from before retirement cannot revive a provider")
    func lateMetadataIsRejected() async throws {
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        let started = CloudLinkFirstValue<Bool>()
        let resume = CloudLinkFirstValue<Bool>()
        let provider = CmuxTuiSurfaceProvider(summary: summary(), links: links, catalog: catalog,
            loadPortSummary: { _ in
                started.resolve(true)
                _ = await resume.result
                return summary(address: "10.0.0.7")
            })
        catalog.register(provider)
        let refresh = Task { try await provider.refreshPortMetadata() }
        _ = await started.result
        await provider.stop()
        resume.resolve(true)
        do {
            try await refresh.value
            Issue.record("A retired provider accepted a late machine summary")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(provider.info.privateAddress == nil)
        #expect(await links.privateAddresses(for: "port-owner").isEmpty)
    }

    @Test("A foreign summary never changes the machine's address")
    func foreignMetadataIsRejected() async {
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        let provider = CmuxTuiSurfaceProvider(summary: summary(), links: links, catalog: catalog,
            loadPortSummary: { _ in summary(id: "foreign", address: "10.0.0.8") })
        catalog.register(provider)
        do {
            try await provider.refreshPortMetadata()
            Issue.record("A foreign summary was accepted")
        } catch {}
        #expect(provider.info.privateAddress == nil)
        #expect(await links.privateAddresses(for: "port-owner").isEmpty)
        await provider.stop()
    }

    @Test("Leaving a failed route cancels and fences its pending retry")
    func retryCannotOverrideNewNavigation() async {
        let state = CloudBrowserAccessState()
        let started = CloudLinkFirstValue<Bool>()
        let resume = CloudLinkFirstValue<Bool>()
        let finished = CloudLinkFirstValue<Bool>()
        var published = false
        state.showUnavailable("Missing address") { [weak state] request in
            started.resolve(true)
            _ = await resume.result
            if state?.isCurrentUnavailableRetry(request) == true { published = true }
            finished.resolve(true)
        }
        state.retryUnavailable()
        _ = await started.result
        state.leave()
        resume.resolve(true)
        _ = await finished.result
        #expect(!published && state.unavailable == nil && state.unavailableRetryAction == nil)
    }

    @Test("In-app proxy access ignores every system VPN phase", arguments: [
        CloudTunnelState.off, .starting, .awaitingApproval, .up, .stopping, .failed("VPN denied")
    ])
    func vpnDoesNotGatePort(_ vpn: CloudTunnelState) async {
        var attempts = 0
        let model = CloudPortAccessModel(target: CloudPortForwardTarget(host: "10.0.0.7", port: 3000),
            coordinator: nil, wake: {}, startForward: { _ in Issue.record("Unexpected system forward"); return 1 },
            stopForward: {}, startBrowserProxy: {
                attempts += 1
                if attempts == 1 { throw URLError(.cannotConnectToHost) }
                return CloudBrowserProxyEndpoint(host: "127.0.0.1", port: 42001, username: "fixture", password: "fixture")
            })
        model.acceptTunnelState(vpn)
        model.connectBrowser()
        #expect(await wait { model.failureMessage != nil })
        model.retry()
        #expect(await wait { model.isReady })
        #expect(attempts == 2 && model.usesBrowserProxy)
        model.acceptTunnelState(.off)
        #expect(model.isReady)
        await model.retire()
    }

    private func sshConnection() -> SSHTuiConnection {
        SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            terminalProfile: .shell, destination: "alice@example.invalid", port: 2222, identityFile: nil,
            sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, configuredRemoteCommand: nil,
            preserveAfterTerminalExit: true
        ))
    }

    private func summary(id: String = "port-owner", address: String? = nil) -> VMSummary {
        VMSummary(id: id, provider: "freestyle", status: "running", image: "fixture", createdAt: 0,
            base: nil, addressIPv4: address)
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }

    /// Runs `body` against an SSH provider whose daemon is `portsDaemonScript`. The catalog,
    /// provider, link and scan request are production paths; only the daemon is a fixture.
    private func withPortsFixture(
        _ body: (URL, CmuxTuiSurfaceProvider, SurfaceCatalog) async throws -> Void
    ) async throws {
        let fixtureID = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cmux-ports-\(fixtureID)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("daemon-fixture")
        try Self.portsDaemonScript.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)
        let connection = SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            terminalProfile: .shell, destination: "ports-fixture-\(fixtureID).invalid", port: nil, identityFile: nil,
            sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, preserveAfterTerminalExit: true
        ))
        let links = SSHTuiLinkManager(
            connection: connection, clientURL: client,
            paths: CloudTuiClientPaths(home: root), isEnabled: { true }
        )
        let catalog = SurfaceCatalog()
        let provider = CmuxTuiSurfaceProvider(summary: .ssh(connection), links: links, catalog: catalog)
        do {
            _ = try await links.connected(machineID: connection.id)
            let link = try #require(await links.link(machineID: connection.id))
            // Drain the connection edge so it cannot start an extra refresh mid-test.
            var changes = link.changes.makeAsyncIterator()
            #expect(await changes.next() == .connected)
            catalog.register(provider)
            try await body(root, provider, catalog)
        } catch {
            catalog.unregister(machine: provider.machine)
            await provider.stop()
            await links.disconnect()
            throw error
        }
        catalog.unregister(machine: provider.machine)
        await provider.stop()
        await links.disconnect()
    }

    private static func portRows(_ catalog: SurfaceCatalog, _ machine: SurfaceMachineID) -> [Int] {
        catalog.authoritativeSnapshot.resources(on: machine).compactMap(\.id.forwardedPort).sorted()
    }

    private static func fixtureFileExists(_ root: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private static func createFixtureFile(_ root: URL, _ name: String) {
        FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil)
    }

    /// Work that crosses a real socket needs sleeps, not main-actor spins.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    // A local protocol peer, started and reaped by the real link. It answers the
    // second port scan only after the test creates `release-scan`, and the first
    // snapshot read after `hold-snapshot` only after `release-snapshot`.
    private static let portsDaemonScript = #"""
    #!/usr/bin/python3
    import json
    import pathlib
    import socket
    import threading
    import time

    root = pathlib.Path(__file__).parent
    path = str(root / "daemon.sock")
    snapshot = {
        "cursor": {"generation": "daemon", "revision": "7"},
        "workspaces": [{"id": "ws_main", "name": "Main"}],
        "screens": [{"id": "screen", "workspace_id": "ws_main"}],
        "panes": [{"id": "pane", "screen_id": "screen"}],
        "tabs": [{"id": "tab", "pane_id": "pane", "name": "Main", "content_kind": "terminal", "content_id": "term"}],
        "terminals": [{"id": "term", "title": "bash", "cwd": "/srv/project", "lifecycle": "running", "stream_revision": "1"}],
        "browsers": [], "agents": []
    }
    listings = [
        "LISTEN 0 128 0.0.0.0:3000 0.0.0.0:*\n",
        "LISTEN 0 128 0.0.0.0:3000 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:8000 0.0.0.0:*\n",
    ]
    scans = 0
    held_snapshot = False
    send_lock = threading.Lock()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(1)
    print(json.dumps({"event": "connection-snapshot", "local_socket": path, "connection": {}}), flush=True)
    peer, _ = listener.accept()

    def send(response):
        with send_lock:
            peer.sendall((json.dumps(response) + "\n").encode())

    def release(response, gate):
        while not (root / gate).exists():
            time.sleep(0.01)
        send(response)

    def hold(response, marker, gate):
        (root / marker).touch()
        threading.Thread(target=release, args=(response, gate), daemon=True).start()

    with peer, peer.makefile("r") as reader:
        for line in reader:
            request = json.loads(line)
            op = request.get("operation", request.get("cmd"))
            params = request.get("params", {})
            response = {"id": request["id"], "ok": True}
            if "operation" in request:
                response.update(protocol="cmux.protocol/2", type="response")
            if op == "session.events":
                result = {"stream_id": params["stream_id"]}
            elif op == "session.snapshot":
                result = snapshot
            elif op == "machine-listening-tcp":
                scans += 1
                result = {"stdout": listings[min(scans, len(listings)) - 1]}
            elif op in ("stream.cancel", "request.cancel"):
                result = {}
            else:
                raise AssertionError("unexpected request: " + op)
            response["result" if "operation" in request else "data"] = result
            if op == "machine-listening-tcp" and scans == 2:
                hold(response, "scan-started", "release-scan")
            elif op == "session.snapshot" and not held_snapshot and (root / "hold-snapshot").exists():
                held_snapshot = True
                hold(response, "snapshot-started", "release-snapshot")
            else:
                send(response)
    """#
}

/// A carrier that never connects, so every refresh takes the link-failure path.
private actor UnreachableLinks: RemoteTuiLinkManaging {
    nonisolated let operations: CloudOperationRecorder? = nil
    func connected(machineID: String) async throws -> CloudMachineLink.Connected { throw URLError(.cannotConnectToHost) }
    func link(machineID: String) async -> CloudMachineLink? { nil }
    func status(machineID: String) async -> CloudMachineLinkManager.LinkStatus? { nil }
    func privateAddresses(for machineID: String) async -> [String] { [] }
    func setPrivateAddresses(_ addresses: [String], for machineID: String) async {}
    func browserProxy(machineID: String) async throws -> CloudBrowserProxyEndpoint { throw URLError(.cannotConnectToHost) }
}
