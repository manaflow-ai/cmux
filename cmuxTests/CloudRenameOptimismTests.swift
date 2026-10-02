import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A rename shows its new name in the Cloud tree the moment it is admitted and
/// falls back to the daemon's name the moment it fails. The catalog snapshot is
/// the one projection every sidebar and socket reader sees, so the sidebar,
/// `surface.catalog`, and `vm tree --json` agree while the request is in flight.
@MainActor
@Suite
struct CloudRenameOptimismTests {
    private struct Rejected: Error {}

    @Test("A workspace rename is visible before its RPC and rolls back when it fails")
    func workspaceRenameShowsImmediatelyAndRollsBackOnFailure() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudRenameTestProvider()
        catalog.register(provider)
        catalog.replaceResources(
            [provider.terminal("term-a", tab: "tab-a"), provider.terminal("term-b", tab: "tab-b")],
            on: provider.machine, info: provider.info
        )
        let gate = RenameGate()
        provider.beforeWorkspaceRename = { await gate.wait(); throw Rejected() }
        let changes = CatalogChangeCounter(catalog: catalog)
        defer { changes.stop() }

        let rename = catalog.enqueueRemoteWorkspaceRename(on: provider.machine, id: provider.workspace.id, name: "Renamed")
        // Admitted synchronously: every place a row reads the name from is renamed.
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.map(\.name) == ["Renamed"])
        #expect(catalog.snapshot.resources.map { $0.remoteWorkspace?.name } == ["Renamed", "Renamed"])
        #expect(catalog.snapshot.resources.flatMap { $0.remoteViews ?? [] }.map(\.workspace.name) == ["Renamed", "Renamed"])
        #expect(catalog.snapshot.pendingWorkspaceDeletions == nil)
        // The authoritative rows are never edited to implement optimism.
        #expect(catalog.authoritativeSnapshot.machines.first?.remoteWorkspaces?.map(\.name) == ["Original"])
        #expect(await changes.reached(1), "the sidebar must be told to redraw when the intent is admitted")

        gate.open()
        await #expect(throws: Rejected.self) { try await rename.value }
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.map(\.name) == ["Original"])
        #expect(catalog.snapshot.resources.map { $0.remoteWorkspace?.name } == ["Original", "Original"])
        #expect(provider.workspaceRenames.isEmpty)
        #expect(await changes.reached(2), "the sidebar must be told to redraw when the intent is released")
    }

    @Test("A tab rename projects onto its exact view; a terminal rename onto every view; empty clears")
    func tabAndTerminalRenamesProjectOntoTheRightViews() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudRenameTestProvider()
        catalog.register(provider)
        var shared = provider.terminal("term-a-shared", tab: "tab-1", name: "one")
        shared.remoteViews?.append(SurfaceRemoteView(tabID: "tab-2", workspace: provider.workspace, name: "two"))
        let other = provider.terminal("term-b-other", tab: "tab-3", name: "three")
        catalog.replaceResources([shared, other], on: provider.machine, info: provider.info)
        let gate = RenameGate()
        provider.beforeTabRename = { await gate.wait() }
        func names() -> [[String?]] { catalog.snapshot.resources.map { $0.remoteViews?.map(\.name) ?? [] } }
        #expect(names() == [["one", "two"], ["three"]])

        let tab = catalog.enqueueRemoteTabRename(on: provider.machine, id: "tab-2", name: "renamed-two")
        #expect(names() == [["one", "renamed-two"], ["three"]])

        // A terminal-wide clear renames every view of that terminal, but the
        // exact tab intent still wins for its own view.
        let clear = catalog.cloudRenameCoordinator.enqueue(
            key: .terminal(machine: provider.machine, id: shared.id.key), pendingName: ""
        ) { await gate.wait() }
        #expect(names() == [[nil, "renamed-two"], ["three"]])
        #expect(catalog.authoritativeSnapshot.resources.map { $0.remoteViews?.map(\.name) ?? [] } == [["one", "two"], ["three"]])

        gate.open()
        try await tab.value
        try await clear.value
        #expect(provider.tabRenames.map { $0.name } == ["renamed-two"])
        // This provider does not re-sync, so the released intents fall back to
        // the accepted rows: nothing invented, nothing stuck.
        #expect(names() == [["one", "two"], ["three"]])
    }

    @Test("An accepted receipt keeps the name after the RPC until the graph carries it")
    func acceptedReceiptKeepsTheNameUntilTheGraphCatchesUp() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudRenameTestProvider()
        catalog.register(provider)
        let stale = try Self.state(machine: provider.machine, workspaceName: "Original", tabName: "old tab")
        let receipts = [
            CloudVMPendingMutation(kind: .workspaceRename, remoteWorkspaceID: "ws_main", name: "Renamed",
                                   receipt: .init(generation: "fixture", revision: 5)),
            CloudVMPendingMutation(kind: .tabRename, remoteTabID: "tab_main", name: "new tab",
                                   receipt: .init(generation: "fixture", revision: 6)),
        ]
        catalog.replaceCloudState(stale, resources: CmuxTuiSnapshotParser.resources(from: stale), info: provider.info,
                                  observation: .init(freshness: .current, reason: nil, pendingWrites: receipts))
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.map(\.name) == ["Renamed"])
        let views = catalog.snapshot.resources.flatMap { $0.remoteViews ?? [] }
        #expect(views.map(\.name) == ["new tab"])
        #expect(views.map(\.workspace.name) == ["Renamed"])
        // A newer intent for the same identity outranks the receipt.
        let gate = RenameGate()
        provider.beforeTabRename = { await gate.wait() }
        let newer = catalog.enqueueRemoteTabRename(on: provider.machine, id: "tab_main", name: "newer tab")
        #expect(catalog.snapshot.resources.flatMap { $0.remoteViews ?? [] }.map(\.name) == ["newer tab"])
        gate.open()
        try await newer.value
        // The intent is released, the receipt still holds until the graph catches up.
        #expect(catalog.snapshot.resources.flatMap { $0.remoteViews ?? [] }.map(\.name) == ["new tab"])

        let accepted = try Self.state(machine: provider.machine, workspaceName: "Renamed", tabName: "new tab", revision: 6)
        catalog.replaceCloudState(accepted, resources: CmuxTuiSnapshotParser.resources(from: accepted), info: provider.info)
        #expect(catalog.authoritativeSnapshot.machines.first?.remoteWorkspaces?.map(\.name) == ["Renamed"])
        #expect(catalog.snapshot.resources.flatMap { $0.remoteViews ?? [] }.map(\.name) == ["new tab"])
    }

    private static func state(
        machine: SurfaceMachineID, workspaceName: String, tabName: String, revision: UInt64 = 1
    ) throws -> CloudVMState {
        let document: [String: Any] = [
            "cursor": ["generation": "fixture", "revision": String(revision)],
            "workspaces": [["id": "ws_main", "name": workspaceName, "index": 0]],
            "screens": [["id": "screen_main", "workspace_id": "ws_main", "layout": [
                "kind": "leaf", "pane_id": "pane_main", "tab_ids": ["tab_main"]]]],
            "panes": [["id": "pane_main", "screen_id": "screen_main"]],
            "tabs": [["id": "tab_main", "pane_id": "pane_main", "index": 0,
                      "name": tabName, "content_kind": "terminal", "content_id": "term_main"]],
            "terminals": [["id": "term_main", "title": "terminal", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
    }
}

/// Holds an in-flight rename until the test has inspected the pending state.
@MainActor
private final class RenameGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }
}

/// Counts catalog change notifications: the signal the Machines panel redraws on.
@MainActor
private final class CatalogChangeCounter {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init(catalog: SurfaceCatalog) {
        token = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification, object: catalog, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    /// Change notifications coalesce onto the next main-actor turn; give them a
    /// few turns to land rather than asserting on one yield.
    func reached(_ expected: Int) async -> Bool {
        for _ in 0..<50 where count < expected { await Task.yield() }
        return count >= expected
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

@MainActor
private final class CloudRenameTestProvider: SurfaceProvider {
    let machine = SurfaceMachineID.cloud("optimistic-rename")
    let workspace = SurfaceRemoteWorkspace(id: "ws_main", name: "Original", index: 0, focused: true)
    var beforeWorkspaceRename: () async throws -> Void = {}
    var beforeTabRename: () async throws -> Void = {}
    var workspaceRenames: [(id: String, name: String)] = []
    var tabRenames: [(id: String, name: String)] = []
    var info: SurfaceMachineInfo {
        SurfaceMachineInfo(id: machine, name: "Test machine", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: [workspace])
    }

    func terminal(_ key: String, tab: String, name: String? = nil) -> SurfaceResource {
        var resource = SurfaceResource(id: .init(machine: machine, kind: .terminal, key: key),
            title: "shell", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: workspace, port: nil, url: nil)
        resource.remoteViews = [SurfaceRemoteView(tabID: tab, workspace: workspace, name: name)]
        return resource
    }

    func refresh() async {}
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
    }
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        terminal("term-new", tab: "tab-new")
    }
    func projectionDidEnd(_ projection: SurfaceProjection) {}
    func renameRemoteWorkspace(id: String, name: String) async throws {
        try await beforeWorkspaceRename()
        workspaceRenames.append((id, name))
    }
    func renameRemoteTab(id: String, name: String) async throws {
        try await beforeTabRename()
        tabRenames.append((id, name))
    }
}
