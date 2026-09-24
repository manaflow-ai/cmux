import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Independent guest displays", .timeLimit(.minutes(1)))
struct CloudDisplayCatalogTests {
    private let initial = #"{"version":1,"canCreate":true,"displays":[{"id":"display:1","number":1,"port":6901,"state":"running"}]}"#
    private let created = #"{"version":1,"canCreate":true,"displays":[{"id":"display:1","number":1,"port":6901,"state":"running"},{"id":"display:2","number":2,"port":6902,"state":"running"}],"created":"display:2"}"#

    @Test("The installed helper keeps Python docstrings valid in the command payload")
    func embeddedGuestScriptIsExecutableText() {
        let command = CloudGuestDisplayScript.command(action: "list")
        #expect(!command.contains(#"\"\"\""#))
        #expect(command.contains("base64 -d"))
    }

    @Test("A lost creation reply replays its receipt rather than allocating another display")
    func creationRetryKeepsRequestIdentity() async throws {
        var creates: [String] = []
        let service = CloudDisplayCoordinator { command, _ in
            if !Self.isCreate(command) { return .init(exitCode: 0, stdout: initial, stderr: "") }
            creates.append(command)
            if creates.count == 1 { throw URLError(.networkConnectionLost) }
            return .init(exitCode: 0, stdout: created, stderr: "")
        }
        await service.refresh()
        #expect(service.canCreate)
        do { _ = try await service.create(); Issue.record("Lost response must fail") } catch {}
        let result = try await service.create()
        #expect(creates.count == 2 && creates[0] == creates[1])
        #expect(result.displays.count == 2)
        #expect(service.snapshot?.displays.first?.id == "display:1")
    }

    @Test("Account/provider retirement prevents a delayed display reply from publishing")
    func retiredCreationCannotPublish() async throws {
        let started = CloudLinkFirstValue<Bool>()
        let response = CloudLinkFirstValue<Bool>()
        let service = CloudDisplayCoordinator { command, _ in
            if !Self.isCreate(command) { return .init(exitCode: 0, stdout: initial, stderr: "") }
            started.resolve(true)
            _ = await response.result
            return .init(exitCode: 0, stdout: created, stderr: "")
        }
        await service.refresh()
        let operation = Task { try await service.create() }
        try #require(await Self.guestExecStarted(started, before: operation))
        service.stop()
        response.resolve(true)
        do { _ = try await operation.value; Issue.record("Retired creation succeeded") } catch {}
        #expect(!service.canCreate)
        #expect(service.snapshot == nil)
    }

    @Test("Unsupported images never expose a fake creation action")
    func unsupportedGuest() async {
        let service = CloudDisplayCoordinator { _, _ in .init(exitCode: 127, stdout: "", stderr: "missing") }
        await service.refresh()
        #expect(!service.canCreate && service.snapshot == nil)
    }

    @Test("A failed guest response cannot publish a valid-looking stale catalog")
    func nonzeroRefreshClearsSnapshot() async {
        var failed = false
        let service = CloudDisplayCoordinator { command, _ in
            if failed { return .init(exitCode: 1, stdout: initial, stderr: "guest unavailable") }
            return .init(exitCode: 0, stdout: initial, stderr: "")
        }
        await service.refresh()
        #expect(service.snapshot != nil)
        failed = true
        await service.refresh()
        #expect(service.snapshot == nil && !service.canCreate)
        #expect(service.displaySnapshot?.displays.count == 1)
    }

    @Test("A failed refresh invalidates the cached guest catalog")
    func failedRefreshClearsSnapshot() async {
        var shouldFail = false
        let service = CloudDisplayCoordinator { command, _ in
            guard command.contains(" list") else { return .init(exitCode: 0, stdout: initial, stderr: "") }
            if shouldFail { throw URLError(.networkConnectionLost) }
            return .init(exitCode: 0, stdout: initial, stderr: "")
        }
        await service.refresh()
        #expect(service.snapshot != nil && service.canCreate)
        shouldFail = true
        await service.refresh()
        #expect(service.snapshot == nil && !service.canCreate)
        #expect(service.displaySnapshot?.displays.count == 1)
    }

    @Test("Cancelling display creation cancels the guest exec")
    func cancelledCreationCancelsGuestExec() async throws {
        let started = CloudLinkFirstValue<Bool>()
        let cancelled = CloudLinkFirstValue<Bool>()
        // Never resolved: the exec stays in flight until its task is cancelled.
        let reply = CloudLinkFirstValue<Bool>()
        let service = CloudDisplayCoordinator { command, _ in
            if !Self.isCreate(command) { return .init(exitCode: 0, stdout: initial, stderr: "") }
            started.resolve(true)
            _ = await reply.result
            cancelled.resolve(Task.isCancelled)
            throw CancellationError()
        }
        await service.refresh()
        let operation = Task { try await service.create() }
        try #require(await Self.guestExecStarted(started, before: operation))
        operation.cancel()
        #expect(await cancelled.result == true)
        do { _ = try await operation.value } catch {}
    }

    @Test("The existing Desktop cannot be reported as a newly created display")
    func rejectsDesktopCreationReceipt() {
        let raw = #"{"version":1,"canCreate":true,"displays":[{"id":"display:1","number":1,"port":6901,"state":"running"}],"created":"display:1"}"#
        #expect(throws: (any Error).self) { try CloudGuestDisplaySnapshot(data: Data(raw.utf8)) }
    }

    @Test("Provider invalidation clears a previously discovered guest catalog")
    func invalidationClearsSnapshot() async {
        let service = CloudDisplayCoordinator { _, _ in
            .init(exitCode: 0, stdout: initial, stderr: "")
        }
        await service.refresh()
        #expect(service.snapshot != nil)
        service.invalidate()
        #expect(service.snapshot == nil && !service.isAvailable)
    }


    @Test("Display IDs and connection targets are scoped to the authenticated VM")
    func independentTargets() throws {
        let snapshot = try decode("""
        {"version":1,"canCreate":true,"displays":[
          {"id":"display:1","number":1,"port":6901,"state":"running"},
          {"id":"display:2","number":2,"port":6902,"state":"running"}],"created":"display:2"}
        """)
        let a = snapshot.displays.map { $0.resource(on: .cloud("a"), address: "10.0.0.7") }
        let b = snapshot.displays.map { $0.resource(on: .cloud("b"), address: "10.0.0.7") }
        #expect(a[0].id != a[1].id)
        #expect(a[1].id != b[1].id, "Reused IP, labels and display IDs cannot confer VM ownership")
        #expect(URL(string: try #require(a[0].url))?.port == 6901)
        #expect(URL(string: try #require(a[1].url))?.port == 6902)
        #expect(SurfaceOwnershipPolicy(cloudMachine: .cloud("a")).rejection(for: b.map(\.id)) != nil)
        #expect(SurfaceOwnershipPolicy(cloudMachine: .cloud("b")).rejection(for: a.map(\.id)) != nil)
        #expect(SurfaceOwnershipPolicy(cloudMachine: .cloud("a")).rejection(for: [a[0].id, a[0].id, a[1].id]) == nil)
        let refreshed = CmuxTuiSurfaceProvider.withPrivateBrowserURL(a[1], privateAddress: "10.0.0.8")
        #expect(refreshed.id == a[1].id)
        #expect(URL(string: try #require(refreshed.url))?.port == 6902)
    }

    @Test("Guest targets cannot alias display one or invent another host", arguments: [
        #"{"id":"display:2","number":2,"port":6901,"state":"running"}"#,
        #"{"id":"display:1","number":2,"port":6902,"state":"running"}"#,
        #"{"id":"display:99","number":99,"port":6999,"state":"running"}"#
    ])
    func rejectsInvalidGuestIdentity(row: String) {
        #expect(throws: (any Error).self) {
            try decode("{\"version\":1,\"canCreate\":true,\"displays\":[\(row)]}")
        }
    }

    @Test("A daemon pointer without a discovered target cannot open the first desktop")
    func unknownDisplayHasNoTarget() {
        let resource = CmuxTuiSnapshotParser.display(machine: .cloud("a"), key: "display:2")
        if case .unsupported = CloudPortRoutePlan.plan(resource: resource, privateAddress: "10.0.0.7") {} else {
            Issue.record("Unknown display aliased the default desktop")
        }
    }

    @Test("Refreshing placements preserves each guest-issued target")
    func mergingViewPointersKeepsTarget() throws {
        let snapshot = try decode("""
        {"version":1,"canCreate":true,"displays":[
          {"id":"display:1","number":1,"port":6901,"state":"running"},
          {"id":"display:2","number":2,"port":6902,"state":"running"}]}
        """)
        let pool = snapshot.displays.map { $0.resource(on: .cloud("a"), address: "10.0.0.7") }
        var pointer = CmuxTuiSnapshotParser.display(machine: .cloud("a"), key: "display:2")
        pointer.remoteViews = [.init(tabID: "tab-a", workspace: .init(id: "ws-a", name: "same", index: 0, focused: false))]
        let resources = CmuxTuiSnapshotParser.mergingDisplays(pool: pool, parsed: [pointer])
        #expect(resources.count == 2)
        let second = try #require(resources.first { $0.id == pointer.id })
        #expect(second.port == 6902 && second.url == pool[1].url)
        #expect(second.remoteViews == pointer.remoteViews)
    }

    @Test("Guest-created displays survive the next daemon publish and display delta")
    func createdDisplaysSurviveDaemonPublish() async throws {
        let machine = SurfaceMachineID.cloud("display-publish")
        let coordinator = CloudDisplayCoordinator { command, _ in
            .init(exitCode: 0, stdout: Self.isCreate(command) ? created : initial, stderr: "")
        }
        var summary = VMSummary(id: "display-publish", provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)
        summary.kind = .desktop
        summary.addressIPv4 = "10.0.0.7"
        let catalog = SurfaceCatalog()
        let provider = CmuxTuiSurfaceProvider(
            summary: summary,
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }),
            catalog: catalog,
            displayCoordinator: coordinator
        )
        catalog.register(provider)
        defer { catalog.unregister(machine: machine) }
        await provider.refreshDisplays()
        let second = try await provider.createDisplay()
        #expect(second.id == SurfaceResourceID(machine: machine, kind: .display, key: "display:2"))

        func displayPorts() -> [String: Int?] {
            Dictionary(uniqueKeysWithValues: catalog.snapshot.resources(on: machine)
                .filter { $0.kind == .display }
                .map { ($0.id.key, $0.port) })
        }
        #expect(displayPorts() == ["display:1": 6901, "display:2": 6902])

        // A daemon graph carries no display tabs; the guest catalog still owns both screens.
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "daemon", "revision": "1"],
            "workspaces": [["id": "ws_main", "name": "main", "focused": true]],
            "screens": [["id": "screen", "workspace_id": "ws_main"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": [["id": "tab_0", "pane_id": "pane", "content_kind": "terminal", "content_id": "term_0", "focused": true]],
            "terminals": [["id": "term_0", "title": "bash", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ], machine: machine))
        #expect(provider.installSnapshotIfNewer(state))
        provider.publish(state, ports: [])
        #expect(displayPorts() == ["display:1": 6901, "display:2": 6902], "a full publish keeps every guest display")

        provider.publishDelta(
            state,
            impact: CloudVMStateDeltaImpact(resourceIDs: [second.id], requiresFullResourceRebuild: false),
            ports: [],
            reconcileTitles: false
        )
        #expect(displayPorts() == ["display:1": 6901, "display:2": 6902], "a delta touching display 2 keeps its target")
        #expect(catalog.resources[second.id]?.url?.contains(":6902/") == true)
    }

    /// Waits until the fake guest exec starts creating, or answers false when
    /// `operation` finishes first. `create()` can fail before it reaches the
    /// exec (a fake that no longer recognizes the create command, for example),
    /// and awaiting `started` alone then parks the test until the suite time
    /// limit, which relaunches the whole app host.
    private static func guestExecStarted(
        _ started: CloudLinkFirstValue<Bool>,
        before operation: Task<CloudGuestDisplaySnapshot, any Error>
    ) async -> Bool {
        Task {
            _ = await operation.result
            started.resolve(false)
        }
        return await started.result == true
    }

    /// Every guest command first runs `list` as a readiness probe (#13196,
    /// 178d35e5da), so only the final action line tells a creation apart.
    private static func isCreate(_ command: String) -> Bool {
        command.contains("\"$path\" create --request-id ")
    }

    @Test("Every guest command probes readiness; only creation carries a request ID")
    func guestCommandShape() {
        let request = UUID()
        let create = CloudGuestDisplayScript.command(action: "create", requestID: request)
        let list = CloudGuestDisplayScript.command(action: "list")
        #expect(create.contains("\"$path\" list > /dev/null 2>&1 || exit 1"))
        #expect(create.contains("\"$path\" create --request-id \(request.uuidString.lowercased())"))
        #expect(Self.isCreate(create) && !Self.isCreate(list))
    }

    private func decode(_ raw: String) throws -> CloudGuestDisplaySnapshot {
        try CloudGuestDisplaySnapshot(data: Data(raw.utf8))
    }
}
