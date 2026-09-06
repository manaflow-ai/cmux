import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The surface catalog: one identity per resource, zero or more projections, one open path.
@MainActor
@Suite
struct SurfaceCatalogTests {
    private struct TestTimeout: Error {}

    @Test("Cloud rename ordering is shared across local windows")
    func cloudRenameCoordinatorSerializesOneRemoteIdentity() async {
        let coordinator = CloudRenameCoordinator()
        let key = CloudRenameCoordinator.Key.tab(machine: .cloud("vm-1"), id: "tab-1")
        let recorder = RenameEventRecorder()

        let first = coordinator.enqueue(key: key, pendingName: "first") {
            recorder.events.append("first-start")
            await Task.yield()
            recorder.events.append("first-end")
        }
        let second = coordinator.enqueue(key: key, pendingName: "second") {
            recorder.events.append("second-start")
            recorder.events.append("second-end")
        }

        #expect(coordinator.pendingName(for: key) == "second")
        _ = try? await second.value
        _ = try? await first.value
        #expect(recorder.events == ["first-start", "first-end", "second-start", "second-end"])
        #expect(coordinator.pendingName(for: key) == nil)
    }

    @Test("Cloud rename ordering shares one machine lane across scopes")
    func cloudRenameCoordinatorSerializesDifferentRemoteIdentities() async {
        let coordinator = CloudRenameCoordinator()
        let machine = SurfaceMachineID.cloud("vm-1")
        let workspaceKey = CloudRenameCoordinator.Key.workspace(machine: machine, id: "workspace-1")
        let tabKey = CloudRenameCoordinator.Key.tab(machine: machine, id: "tab-1")
        let recorder = RenameEventRecorder()

        let workspace = coordinator.enqueue(key: workspaceKey, pendingName: "workspace") {
            recorder.events.append("workspace-start")
            await Task.yield()
            recorder.events.append("workspace-end")
        }
        let tab = coordinator.enqueue(key: tabKey, pendingName: "tab") {
            recorder.events.append("tab-start")
            recorder.events.append("tab-end")
        }

        _ = try? await tab.value
        _ = try? await workspace.value
        #expect(recorder.events == ["workspace-start", "workspace-end", "tab-start", "tab-end"])
        #expect(coordinator.pendingName(for: workspaceKey) == nil)
        #expect(coordinator.pendingName(for: tabKey) == nil)
    }

    @Test("Cloud rename coordinator preserves an empty pending tab name")
    func cloudRenameCoordinatorPreservesEmptyPendingTabName() async throws {
        let coordinator = CloudRenameCoordinator()
        let key = CloudRenameCoordinator.Key.tab(machine: .cloud("vivid-newt"), id: "tab-1")
        let operation = coordinator.enqueue(key: key, pendingName: "") {}
        #expect(coordinator.pendingName(for: key) == "")
        try await operation.value
        #expect(coordinator.pendingName(for: key) == nil)
    }

    @MainActor
    private final class RenameEventRecorder {
        var events: [String] = []
    }

    @Test("Explicit remote placement fails closed without view metadata")
    func explicitRemotePlacementFailsClosedWithoutViewMetadata() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)
        let id = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_1")
        var resource = terminal(machine, "term_1")
        resource.remoteViews = nil
        catalog.upsert(resource)

        #expect(throws: SurfaceCatalogError.unavailable(
            id,
            reason: "remote placement data is unavailable"
        )) {
            try catalog.remoteView(for: id, tabID: "tab_1")
        }
    }

    @Test("Duplicate remote tab placement fails closed")
    func duplicateRemoteTabPlacementFailsClosed() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)
        let id = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_1")
        var resource = terminal(machine, "term_1")
        let workspace = SurfaceRemoteWorkspace(id: "ws_1", name: "main", index: 0, focused: true)
        resource.remoteViews = [
            SurfaceRemoteView(tabID: "tab_1", workspace: workspace),
            SurfaceRemoteView(tabID: "tab_1", workspace: workspace),
        ]
        catalog.upsert(resource)

        #expect(throws: SurfaceCatalogError.unavailable(
            id,
            reason: "remote tab tab_1 has ambiguous placement"
        )) {
            try catalog.remoteView(for: id, tabID: "tab_1")
        }
    }

    /// Lets timeout behavior be tested without waiting on wall-clock time.
    private final class ImmediateClock: Clock, @unchecked Sendable {
        typealias Instant = ContinuousClock.Instant

        private let lock = NSLock()
        private var sleepCount = 0
        private let onSleep: @Sendable (Int) -> Void

        init(onSleep: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.onSleep = onSleep
        }

        var now: Instant { .now }
        var minimumResolution: Duration { .zero }

        func sleep(until _: Instant, tolerance _: Duration?) async throws {
            await Task.yield()
            let count = lock.withLock {
                sleepCount += 1
                return sleepCount
            }
            onSleep(count)
        }
    }

    /// Await a test signal without allowing a broken setup to hang the test process.
    private nonisolated func awaitFirst<T: Sendable>(
        _ stream: AsyncStream<T>,
        timeout: Duration = .seconds(1)
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let value = await iterator.next() else { throw TestTimeout() }
                return value
            }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                throw TestTimeout()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw TestTimeout() }
            return value
        }
    }

    @MainActor
    private final class MaterializeGate {
        private(set) var entered = false
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { continuation in
                enteredContinuation = continuation
            }
        }

        func block() async {
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }

        func release() {
            let continuations = releaseContinuations
            releaseContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }
    }

    private final class FakeProvider: SurfaceProvider {
        let machine: SurfaceMachineID
        var info: SurfaceMachineInfo
        var materialized: [(SurfaceResourceID, SurfaceDestination)] = []
        var ended: [SurfaceProjection] = []
        var discarded: [SurfaceProjection] = []
        var discardInvocations: [SurfaceProjection] = []
        var onDiscard: ((SurfaceProjection) -> Void)?
        var onMaterialize: (() -> Void)?
        var materializationPreserved = false
        /// Every materialize makes a new pane, as real providers do; a fixed id would let
        /// the catalog's projection set collapse a deliberate second pane into the first.
        var nextPanel = UUID()
        var materializeGate: MaterializeGate?

        init(machine: SurfaceMachineID) {
            self.machine = machine
            info = SurfaceMachineInfo(id: machine, name: machine.rawValue, status: "running", image: nil, hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
        }

        func refresh() async {}

        func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
            materialized.append((resource.id, destination))
            await materializeGate?.block()
            let panelID = nextPanel
            nextPanel = UUID()
            onMaterialize?()
            return SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: panelID)
        }

        func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
            SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_new"), title: name ?? "shell", detail: cwd, lifecycle: .launching, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
        }

        var closedTerminals: [SurfaceResourceID] = []
        var closedRemoteWorkspaces: [String] = []
        var renamedRemoteWorkspaces: [(id: String, name: String)] = []
        /// Interleaved order of the remote mutations, so tests can assert terminals
        /// die BEFORE their workspace closes (the delete contract).
        var remoteMutationLog: [String] = []

        func closeTerminal(_ id: SurfaceResourceID) async throws {
            closedTerminals.append(id)
            remoteMutationLog.append("terminal:\(id.key)")
        }

        func closeRemoteWorkspace(id: String) async throws {
            closedRemoteWorkspaces.append(id)
            remoteMutationLog.append("workspace:\(id)")
        }

        func renameRemoteWorkspace(id: String, name: String) async throws {
            renamedRemoteWorkspaces.append((id: id, name: name))
        }

        func projectionDidEnd(_ projection: SurfaceProjection) { ended.append(projection) }

        @discardableResult
        func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
            discardInvocations.append(projection)
            onDiscard?(projection)
            guard !materializationPreserved else { return true }
            discarded.append(projection)
            return false
        }
    }

    private func terminal(_ machine: SurfaceMachineID, _ key: String, title: String = "shell") -> SurfaceResource {
        SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: "/root", lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
    }

    @Test("Cloud delta patch preserves unaffected capability rows")
    func cloudDeltaPatchPreservesUnaffectedRows() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)

        let snapshot: [String: Any] = [
            "cursor": ["generation": "g1", "revision": "1"],
            "workspaces": [["id": "ws", "name": "main"]],
            "screens": [["id": "screen", "workspace_id": "ws"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": [
                ["id": "tab_one", "pane_id": "pane", "content_kind": "terminal", "content_id": "term_one", "name": "one"],
                ["id": "tab_two", "pane_id": "pane", "content_kind": "terminal", "content_id": "term_two", "name": "two"],
            ],
            "terminals": [
                ["id": "term_one", "tab_id": "tab_one", "tab_ids": ["tab_one"], "title": "old", "lifecycle": "running"],
                ["id": "term_two", "tab_id": "tab_two", "tab_ids": ["tab_two"], "title": "untouched", "lifecycle": "running"],
            ],
            "browsers": [],
            "agents": [],
        ]
        let initial = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        let termOne = try #require(CmuxTuiSnapshotParser.resources(from: initial).first { $0.id.key == "term_one" })
        let termTwo = try #require(CmuxTuiSnapshotParser.resources(from: initial).first { $0.id.key == "term_two" })
        let port = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 3000)
        catalog.replaceCloudState(initial, resources: [termOne, termTwo, port], info: provider.info)
        #expect(catalog.hasResources(on: machine))

        let delta: [String: Any] = [
            "changes": [[
                "kind": "upsert",
                "resource": "tab",
                "id": "tab_one",
                "value": ["id": "tab_one", "pane_id": "pane", "content_kind": "terminal", "content_id": "term_one", "name": "new"],
            ]],
        ]
        let application = try #require(CmuxTuiSnapshotParser.applyingWithImpact(
            deltaPayload: try JSONSerialization.data(withJSONObject: delta),
            cursor: CloudVMCursor(generation: "g1", revision: 2),
            to: initial
        ))
        let updated = try #require(CmuxTuiSnapshotParser.resources(from: application.state, matching: application.impact.resourceIDs).first { $0.id.key == "term_one" })
        _ = catalog.applyCloudStateResourcePatch(
            application.state,
            resources: [updated],
            affectedResourceIDs: application.impact.resourceIDs,
            info: provider.info
        )

        #expect(catalog.snapshot.resources(on: machine).first { $0.id.key == "term_one" }?.title == "new")
        #expect(catalog.snapshot.resources(on: machine).contains(termTwo))
        #expect(catalog.snapshot.resources(on: machine).contains(port))
        #expect(catalog.cloudStates[machine]?.cursor == CloudVMCursor(generation: "g1", revision: 2))
        #expect(catalog.hasResources(on: machine))
    }

    @Test("Cloud unavailable replacement keeps the reverse resource index exact")
    func cloudUnavailableReplacementKeepsResourceIndexExact() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)

        let snapshot: [String: Any] = [
            "cursor": ["generation": "g1", "revision": "1"],
            "workspaces": [["id": "ws", "name": "main"]],
            "screens": [],
            "panes": [],
            "tabs": [],
            "terminals": [["id": "term", "tab_ids": [], "title": "shell", "lifecycle": "running"]],
            "browsers": [],
            "agents": [],
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        let terminal = try #require(CmuxTuiSnapshotParser.resources(from: state).first)
        catalog.replaceCloudState(state, resources: [terminal], info: provider.info)
        #expect(catalog.hasResources(on: machine))

        catalog.replaceUnavailableCloudState(on: machine, resources: [], info: provider.info)
        #expect(catalog.snapshot.resources(on: machine).isEmpty)
        #expect(!catalog.hasResources(on: machine))

        catalog.replaceUnavailableCloudState(on: machine, resources: [terminal], info: provider.info)
        #expect(catalog.hasResources(on: machine))
    }

    @Test("Stale machine metadata cannot regress the accepted cloud workspace graph")
    func staleMachineMetadataPreservesCanonicalWorkspaceNames() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)
        let snapshot: [String: Any] = [
            "cursor": ["generation": "g1", "revision": "1"],
            "workspaces": [["id": "ws", "name": "canonical"]],
            "screens": [],
            "panes": [],
            "tabs": [],
            "terminals": [],
            "browsers": [],
            "agents": [],
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        var canonicalInfo = provider.info
        canonicalInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "canonical", index: 0, focused: true),
        ]
        catalog.replaceCloudState(state, resources: [], info: canonicalInfo)

        var staleInfo = provider.info
        staleInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "old-name", index: 0, focused: false),
            SurfaceRemoteWorkspace(id: "removed", name: "removed", index: 1, focused: false),
        ]
        catalog.updateMachine(staleInfo, from: provider)

        #expect(catalog.machines[machine]?.remoteWorkspaces == [
            SurfaceRemoteWorkspace(id: "ws", name: "canonical", index: 0, focused: true),
        ])
    }

    @Test func `Resource ID round trips through the wire form`() {
        let id = SurfaceResourceID(machine: .cloud("vivid-newt"), kind: .browser, key: "port:8000/https://x.y/z")
        #expect(id.rawValue == "vivid-newt/browser/port:8000/https://x.y/z")
        #expect(SurfaceResourceID(rawValue: id.rawValue) == id)
        #expect(SurfaceResourceID(rawValue: "local/terminal/ABC")?.machine == .local)
        #expect(SurfaceResourceID(rawValue: "local/nope/x") == nil)
        #expect(SurfaceResourceID(rawValue: "local/terminal/") == nil)
    }

    @Test func `Project materializes once and reuses the open pane`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("vivid-newt"))
        catalog.register(provider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))
        var focused: [SurfaceProjection] = []
        catalog.focusProjection = { focused.append($0) }

        let ws = UUID()
        let first = try await catalog.project(term.id, into: .workspace(id: ws, placement: .split))
        #expect(!first.reused)
        #expect(provider.materialized.count == 1)
        #expect(catalog.projections(of: term.id).count == 1)
        #expect(catalog.snapshot.isOpen(term.id))

        let second = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .tab))
        #expect(second.reused)
        #expect(second.projection == first.projection)
        #expect(provider.materialized.count == 1, "reuse must not materialize a second pane")
        #expect(focused == [first.projection])

        let third = try await catalog.project(term.id, into: .workspace(id: ws, placement: .split), reuseExisting: false)
        #expect(!third.reused)
        #expect(catalog.projections(of: term.id).count == 2)
    }

    @Test func `Workspace-scoped reuse ignores panes in other workspaces`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("vivid-newt"))
        catalog.register(provider)
        let term = terminal(.cloud("vivid-newt"), "display_like")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))
        var focused: [SurfaceProjection] = []
        catalog.focusProjection = { focused.append($0) }

        let wsA = UUID()
        let wsB = UUID()
        let a = try await catalog.project(term.id, into: .workspace(id: wsA, placement: .split), reuseInWorkspace: wsA)
        #expect(!a.reused)

        // A pane in wsA neither satisfies wsB's scoped open nor steals focus:
        // the resource materializes in wsB (the workspace-Desktop-row bug).
        let b = try await catalog.project(term.id, into: .workspace(id: wsB, placement: .split), reuseInWorkspace: wsB)
        #expect(!b.reused)
        #expect(b.projection.workspaceID == wsB)
        #expect(provider.materialized.count == 2)
        #expect(focused.isEmpty, "no jump to the other workspace's pane")

        // Scoped reuse still reuses within its own workspace…
        let again = try await catalog.project(term.id, into: .workspace(id: wsB, placement: .split), reuseInWorkspace: wsB)
        #expect(again.reused)
        #expect(again.projection == b.projection)
        #expect(focused == [b.projection])

        // …and an unscoped call keeps the global open-or-focus jump.
        let global = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .tab))
        #expect(global.reused)
        #expect(provider.materialized.count == 2)
    }

    @Test func `Concurrent reuse waits for the in-flight materialization`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("vivid-newt"))
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))
        let destination = SurfaceDestination.workspace(id: UUID(), placement: .split)

        let first = Task { try await catalog.project(term.id, into: destination) }
        await gate.waitUntilEntered()

        let (secondStarted, secondStartedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let second = Task { @MainActor in
            secondStartedContinuation.yield(())
            secondStartedContinuation.finish()
            return try await catalog.project(term.id, into: destination)
        }
        _ = try await awaitFirst(secondStarted)
        #expect(provider.materialized.count == 1, "a concurrent reuse must share the pending provider call")

        gate.release()
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(!firstResult.reused)
        #expect(secondResult.reused)
        #expect(firstResult.projection == secondResult.projection)
        #expect(catalog.projections(of: term.id).count == 1)
    }

    @Test func `An adopted projection wins a materialization race`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("vivid-newt"))
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))
        let destination = SurfaceDestination.workspace(id: UUID(), placement: .split)

        let project = Task { try await catalog.project(term.id, into: destination) }
        await gate.waitUntilEntered()
        let adopted = SurfaceProjection(resource: term.id, workspaceID: UUID(), panelID: UUID())
        catalog.record(adopted)
        gate.release()

        let result = try await project.value
        #expect(result.reused)
        #expect(result.projection == adopted)
        #expect(provider.discarded.count == 1)
        #expect(provider.discarded.first?.panelID != adopted.panelID)
        #expect(catalog.projections(of: term.id) == [adopted])
    }

    @Test func `Cancelling the last project caller detaches without leaking a late materialization`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("vivid-newt"))
        let (discarded, discardedContinuation) = AsyncStream<SurfaceProjection>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        provider.onDiscard = { projection in
            discardedContinuation.yield(projection)
            discardedContinuation.finish()
        }
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))

        let project = Task { try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split)) }
        await gate.waitUntilEntered()

        let (cancellationResult, cancellationResultContinuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let observer = Task { @MainActor in
            do {
                _ = try await project.value
                cancellationResultContinuation.yield(false)
            } catch is CancellationError {
                cancellationResultContinuation.yield(true)
            } catch {
                cancellationResultContinuation.yield(false)
            }
            cancellationResultContinuation.finish()
        }
        project.cancel()
        let cancelledBeforeRelease = try await awaitFirst(cancellationResult)
        #expect(cancelledBeforeRelease, "cancelling the caller must not wait for the provider")

        gate.release()
        await observer.value
        _ = try await awaitFirst(discarded)
        #expect(catalog.projections.isEmpty)
        #expect(provider.discarded.count == 1, "a late provider result must close the pane after the last caller cancels")
    }

    @Test func `Cancellation at provider completion discards an unclaimed projection`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("vivid-newt"))
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))

        var project: Task<SurfaceProjectionMaterialization.Result, any Error>?
        let task = Task { @MainActor in
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }
        project = task
        await gate.waitUntilEntered()
        provider.onMaterialize = { project?.cancel() }
        gate.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        provider.onMaterialize = nil
        #expect(catalog.projections.isEmpty)
        #expect(provider.discarded.count == 1)
    }

    @Test func `A removed local resource is not resurrected by a late materialization`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .local)
        provider.materializationPreserved = true
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.local, "term_1")
        catalog.replaceResources([term], on: .local)

        provider.onMaterialize = { catalog.remove(term.id) }
        let project = Task { @MainActor in
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }
        await gate.waitUntilEntered()
        gate.release()

        await #expect(throws: SurfaceCatalogError.unknownResource(term.id)) {
            try await project.value
        }
        #expect(catalog.projections.isEmpty)
        #expect(provider.discardInvocations.count == 1)
    }

    @Test func `A preserving materialization remains recorded when its caller cancels`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .local)
        provider.materializationPreserved = true
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.local, "term_1")
        catalog.replaceResources([term], on: .local)

        var project: Task<SurfaceProjectionMaterialization.Result, any Error>?
        let task = Task { @MainActor in
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }
        project = task
        await gate.waitUntilEntered()
        provider.onMaterialize = { project?.cancel() }
        gate.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        provider.onMaterialize = nil
        #expect(catalog.projections(of: term.id).count == 1)
        #expect(provider.discardInvocations.count == 1)
        #expect(provider.discarded.isEmpty)
    }

    @Test func `An abandoned materialization deadline allows a replacement operation`() async throws {
        let (retirementDeadline, retirementDeadlineContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let clock = ImmediateClock { sleepCount in
            guard sleepCount == 2 else { return }
            retirementDeadlineContinuation.yield(())
            retirementDeadlineContinuation.finish()
        }
        let catalog = SurfaceCatalog(
            abandonedMaterializationTimeout: .seconds(30),
            retiredMaterializationRetention: .seconds(30),
            materializationClock: clock
        )
        let oldProvider = FakeProvider(machine: .cloud("vivid-newt"))
        let (discarded, discardedContinuation) = AsyncStream<SurfaceProjection>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        oldProvider.onDiscard = { projection in
            discardedContinuation.yield(projection)
            discardedContinuation.finish()
        }
        let gate = MaterializeGate()
        oldProvider.materializeGate = gate
        catalog.register(oldProvider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))

        let first = Task { try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split)) }
        await gate.waitUntilEntered()
        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }

        let replacementProvider = FakeProvider(machine: .cloud("vivid-newt"))
        catalog.register(replacementProvider)
        let replacement = Task {
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }
        defer {
            replacement.cancel()
            gate.release()
        }

        let result = try await withThrowingTaskGroup(of: SurfaceProjectionMaterialization.Result.self) { group in
            group.addTask { try await replacement.value }
            group.addTask {
                try await ContinuousClock().sleep(for: .seconds(1))
                throw TestTimeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TestTimeout() }
            return result
        }
        #expect(result.reused == false)
        #expect(replacementProvider.materialized.count == 1)

        _ = try await awaitFirst(retirementDeadline)
        await Task.yield()
        gate.release()
        _ = try await awaitFirst(discarded)
        #expect(oldProvider.discarded.count == 1, "a result after retirement eviction must still close its pane")
    }

    @Test func `Unregistering cancels in-flight materialization`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("vivid-newt"))
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))

        let project = Task { try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split)) }
        await gate.waitUntilEntered()
        catalog.unregister(machine: .cloud("vivid-newt"))
        gate.release()

        await #expect(throws: SurfaceCatalogError.unknownResource(term.id)) {
            try await project.value
        }
        #expect(catalog.projections.isEmpty)
    }

    @Test func `Registering a replacement provider retires its old materialization`() async throws {
        let catalog = SurfaceCatalog()
        let oldProvider = FakeProvider(machine: .cloud("vivid-newt"))
        let gate = MaterializeGate()
        oldProvider.materializeGate = gate
        catalog.register(oldProvider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))

        let oldProject = Task {
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }
        await gate.waitUntilEntered()

        let replacementProvider = FakeProvider(machine: .cloud("vivid-newt"))
        catalog.register(replacementProvider)
        await #expect(throws: SurfaceCatalogError.unknownResource(term.id)) {
            try await oldProject.value
        }

        let newProject = Task {
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }
        gate.release()
        let result = try await newProject.value
        #expect(replacementProvider.materialized.count == 1)
        #expect(oldProvider.discarded.count == 1)
        #expect(result.projection == catalog.projections(of: term.id).first)
    }

    @Test func `Tracked materialization capacity bounds permanently detached work per machine`() async throws {
        let catalog = SurfaceCatalog(maximumTrackedMaterializations: 1)
        let oldProvider = FakeProvider(machine: .cloud("vivid-newt"))
        let gate = MaterializeGate()
        oldProvider.materializeGate = gate
        catalog.register(oldProvider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))

        let oldProject = Task {
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }
        await gate.waitUntilEntered()
        oldProject.cancel()
        await #expect(throws: CancellationError.self) {
            try await oldProject.value
        }

        let second = terminal(.cloud("vivid-newt"), "term_2")
        catalog.upsert(second)
        await #expect(throws: SurfaceCatalogError.unavailable(second.id, reason: "materialization capacity exhausted")) {
            try await catalog.project(second.id, into: .workspace(id: UUID(), placement: .split))
        }

        gate.release()
        #expect(oldProvider.materialized.count == 1)
    }

    @Test func `Tracked materialization capacity is isolated per machine`() async throws {
        let catalog = SurfaceCatalog(maximumTrackedMaterializations: 1)
        let stuckProvider = FakeProvider(machine: .cloud("stuck"))
        let gate = MaterializeGate()
        stuckProvider.materializeGate = gate
        catalog.register(stuckProvider)
        let stuckTerm = terminal(.cloud("stuck"), "term_1")
        catalog.replaceResources([stuckTerm], on: .cloud("stuck"))

        let stuckProject = Task {
            try await catalog.project(stuckTerm.id, into: .workspace(id: UUID(), placement: .split))
        }
        await gate.waitUntilEntered()
        stuckProject.cancel()
        await #expect(throws: CancellationError.self) {
            try await stuckProject.value
        }

        let healthyProvider = FakeProvider(machine: .cloud("healthy"))
        catalog.register(healthyProvider)
        let healthyTerm = terminal(.cloud("healthy"), "term_1")
        catalog.replaceResources([healthyTerm], on: .cloud("healthy"))
        let result = try await catalog.project(healthyTerm.id, into: .workspace(id: UUID(), placement: .split))
        #expect(result.projection.resource == healthyTerm.id)
        #expect(healthyProvider.materialized.count == 1)

        gate.release()
    }

    @Test func `Tracked materialization capacity spans provider replacement`() async throws {
        let catalog = SurfaceCatalog(maximumTrackedMaterializations: 1)
        let oldProvider = FakeProvider(machine: .cloud("vivid-newt"))
        let gate = MaterializeGate()
        oldProvider.materializeGate = gate
        catalog.register(oldProvider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))

        let oldProject = Task {
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }
        await gate.waitUntilEntered()
        oldProject.cancel()
        await #expect(throws: CancellationError.self) {
            try await oldProject.value
        }

        let replacementProvider = FakeProvider(machine: .cloud("vivid-newt"))
        catalog.register(replacementProvider)
        await #expect(throws: SurfaceCatalogError.unavailable(term.id, reason: "materialization capacity exhausted")) {
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }

        gate.release()
    }

    @Test func `Retired materialization eviction releases its machine capacity`() async throws {
        let (evictionStarted, evictionStartedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let clock = ImmediateClock { sleepCount in
            guard sleepCount == 2 else { return }
            evictionStartedContinuation.yield(())
            evictionStartedContinuation.finish()
        }
        let catalog = SurfaceCatalog(
            abandonedMaterializationTimeout: .seconds(30),
            retiredMaterializationRetention: .seconds(30),
            maximumTrackedMaterializations: 1,
            materializationClock: clock
        )
        let oldProvider = FakeProvider(machine: .cloud("vivid-newt"))
        let oldGate = MaterializeGate()
        oldProvider.materializeGate = oldGate
        catalog.register(oldProvider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))

        let oldProject = Task {
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }
        await oldGate.waitUntilEntered()
        oldProject.cancel()
        await #expect(throws: CancellationError.self) {
            try await oldProject.value
        }

        _ = try await awaitFirst(evictionStarted)
        await Task.yield()

        let replacementProvider = FakeProvider(machine: .cloud("vivid-newt"))
        catalog.register(replacementProvider)
        let replacement = try await catalog.project(
            term.id,
            into: .workspace(id: UUID(), placement: .split)
        )
        #expect(!replacement.reused)
        #expect(replacementProvider.materialized.count == 1)

        oldGate.release()
    }

    @Test func `A replacement provider does not join retired materialization`() async throws {
        let catalog = SurfaceCatalog()
        let oldProvider = FakeProvider(machine: .cloud("vivid-newt"))
        let gate = MaterializeGate()
        oldProvider.materializeGate = gate
        catalog.register(oldProvider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))

        let oldProject = Task { try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split)) }
        await gate.waitUntilEntered()
        catalog.unregister(machine: .cloud("vivid-newt"))
        await #expect(throws: SurfaceCatalogError.unknownResource(term.id)) {
            try await oldProject.value
        }

        let newProvider = FakeProvider(machine: .cloud("vivid-newt"))
        catalog.register(newProvider)
        catalog.replaceResources([term], on: .cloud("vivid-newt"))
        let newProject = Task { try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split)) }

        gate.release()
        let result = try await newProject.value
        #expect(newProvider.materialized.count == 1)
        #expect(oldProvider.discarded.count == 1)
        #expect(result.projection == catalog.projections(of: term.id).first)
    }

    @Test func `Ending a projection keeps the remote resource and tells the provider`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("m"))
        catalog.register(provider)
        let term = terminal(.cloud("m"), "term_1")
        catalog.replaceResources([term], on: .cloud("m"))
        let projection = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split)).projection

        catalog.endProjections(panelID: projection.panelID)
        #expect(catalog.projections(of: term.id).isEmpty)
        #expect(catalog.snapshot.resources.first { $0.id == term.id } != nil, "closing a pane never destroys a remote resource")
        #expect(provider.ended == [projection])
    }

    @Test func `Moving a pane moves its projection`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .local)
        catalog.register(provider)
        let term = terminal(.local, "ABC")
        catalog.replaceResources([term], on: .local)
        let projection = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split)).projection
        let other = UUID()
        catalog.moveProjections(panelID: projection.panelID, to: other)
        #expect(catalog.projection(forPanel: projection.panelID)?.workspaceID == other)
    }

    @Test func `Restored projections resolve when the provider reports the resource`() {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("m"))
        catalog.register(provider)
        let ws = UUID(), panel = UUID()
        let id = SurfaceResourceID(machine: .cloud("m"), kind: .terminal, key: "term_9")
        catalog.restore([SurfaceProjectionRecord(panelID: panel, resource: id)], workspaceID: ws)
        #expect(!catalog.snapshot.isOpen(id), "unknown until the link reports it")

        catalog.replaceResources([terminal(.cloud("m"), "term_9")], on: .cloud("m"))
        #expect(catalog.projection(forPanel: panel) == SurfaceProjection(resource: id, workspaceID: ws, panelID: panel))
        #expect(catalog.projectionRecords(forWorkspace: ws) == [SurfaceProjectionRecord(panelID: panel, resource: id)])
    }

    @Test func `Snapshot orders local first, then by name and workspace index`() {
        let catalog = SurfaceCatalog()
        catalog.register(FakeProvider(machine: .cloud("zeta")))
        catalog.register(FakeProvider(machine: .cloud("alpha")))
        catalog.register(FakeProvider(machine: .local))
        var t1 = terminal(.cloud("alpha"), "term_b"); t1.remoteWorkspace = SurfaceRemoteWorkspace(id: "ws_1", name: "1", index: 1, focused: false)
        var t0 = terminal(.cloud("alpha"), "term_a"); t0.remoteWorkspace = SurfaceRemoteWorkspace(id: "ws_0", name: "0", index: 0, focused: true)
        catalog.replaceResources([t1, t0], on: .cloud("alpha"))
        let snapshot = catalog.snapshot
        #expect(snapshot.machines.map { $0.id } == [.local, .cloud("alpha"), .cloud("zeta")])
        #expect(snapshot.resources(on: .cloud("alpha")).map { $0.id.key } == ["term_a", "term_b"])
    }

    @Test func `Opening a group as a new workspace lays every resource out as its own pane`() async throws {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.cloud("vm-1")
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)
        let ids = ["a", "b", "c", "d"].map { SurfaceResourceID(machine: machine, kind: .terminal, key: $0) }
        catalog.replaceResources(ids.map { terminal(machine, $0.key) }, on: machine)

        let newWorkspace = UUID()
        let starter = UUID()
        var created: [String] = []
        var closedStarters: [(UUID, UUID)] = []
        var lookups = 0
        let host = SurfaceCatalog.NewWorkspaceHost(
            create: { title in created.append(title); return (newWorkspace, starter) },
            paneLookup: { _, _ in lookups += 1; return "pane-\(lookups)" },
            closeStarter: { panel, workspace in closedStarters.append((panel, workspace)) }
        )

        let opened = try await catalog.projectGroupAsNewLocalWorkspace(ids, title: "vm-1: main", focus: true, host: host)

        #expect(created == ["vm-1: main"])
        #expect(opened.workspaceID == newWorkspace)
        #expect(opened.projections.count == 4)
        // The first resource takes the starter pane's place; the rest split the previous
        // pane, alternating right and down, so four terminals form a grid.
        let destinations = provider.materialized.map(\.1)
        #expect(destinations[0] == .workspace(id: newWorkspace, placement: .split))
        #expect(destinations[1] == .split(workspaceID: newWorkspace, paneID: "pane-1", direction: .right))
        #expect(destinations[2] == .split(workspaceID: newWorkspace, paneID: "pane-2", direction: .down))
        #expect(destinations[3] == .split(workspaceID: newWorkspace, paneID: "pane-3", direction: .right))
        #expect(closedStarters.count == 1)
        #expect(closedStarters.first?.0 == starter)
        #expect(closedStarters.first?.1 == newWorkspace)
        #expect(catalog.snapshot.projections.count == 4)
    }

    @Test func `Opening an unknown group as a new workspace closes the empty workspace again`() async {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.cloud("vm-1")
        catalog.register(FakeProvider(machine: machine))
        let starter = UUID(), newWorkspace = UUID()
        var closedStarters = 0
        let host = SurfaceCatalog.NewWorkspaceHost(
            create: { _ in (newWorkspace, starter) },
            paneLookup: { _, _ in nil },
            closeStarter: { _, _ in closedStarters += 1 }
        )
        do {
            _ = try await catalog.projectGroupAsNewLocalWorkspace(
                [SurfaceResourceID(machine: machine, kind: .terminal, key: "missing")], title: "x", focus: true, host: host
            )
            Issue.record("expected the unknown resource to fail")
        } catch {
            #expect(closedStarters == 1, "nothing landed, so the empty workspace's starter pane is closed")
        }
    }

    @Test func `Unregistering a machine drops its resources and projections`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("m"))
        catalog.register(provider)
        let term = terminal(.cloud("m"), "term_1")
        catalog.replaceResources([term], on: .cloud("m"))
        #expect(catalog.hasResources(on: .cloud("m")))
        _ = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        catalog.unregister(machine: .cloud("m"))
        #expect(catalog.snapshot.resources.isEmpty)
        #expect(!catalog.hasResources(on: .cloud("m")))
        #expect(catalog.snapshot.projections.isEmpty)
        #expect(catalog.provider(for: .cloud("m")) == nil)
    }

    @Test func `A late refresh from a deleted machine cannot resurrect catalog state`() {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.cloud("gone")
        let provider = FakeProvider(machine: machine)
        let term = terminal(machine, "term_late")

        catalog.register(provider)
        catalog.replaceResources([term], on: machine)
        catalog.unregister(machine: machine)

        // The old provider can finish a refresh after unregister has returned.
        // Those writes are stale and must not put the machine back in the tree.
        catalog.replaceResources([term], on: machine, info: provider.info)
        catalog.upsert(term)
        catalog.updateMachine(provider.info)

        #expect(catalog.provider(for: machine) == nil)
        #expect(catalog.snapshot.machines.contains(where: { $0.id == machine }) == false)
        #expect(catalog.snapshot.resources.contains(where: { $0.machine == machine }) == false)
    }

    @Test func `A retired provider cannot write through its replacement`() {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.cloud("reused")
        let retired = FakeProvider(machine: machine)
        let replacement = FakeProvider(machine: machine)
        let resourceID = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_1")
        let current = SurfaceResource(id: resourceID, title: "current", detail: "/root", lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
        var stale = current
        stale.title = "stale"

        catalog.register(retired)
        catalog.replaceResources([current], on: machine, from: retired)
        catalog.register(replacement)
        catalog.replaceResources([current], on: machine, from: replacement)

        // A refresh that was already in flight on the retired provider must not
        // overwrite either the replacement's resource or machine metadata.
        catalog.replaceResources([stale], on: machine, from: retired)
        catalog.upsert(stale, from: retired)
        var retiredInfo = retired.info
        retiredInfo.name = "retired"
        catalog.updateMachine(retiredInfo, from: retired)

        #expect(catalog.resources[resourceID]?.title == "current")
        #expect(catalog.machines[machine]?.name == replacement.info.name)
    }

    @Test func `Unregister removes pending restores before a machine ID is reused`() {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.cloud("reused")
        let original = FakeProvider(machine: machine)
        let replacement = FakeProvider(machine: machine)
        let panelID = UUID()
        let resourceID = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_old")
        let record = SurfaceProjectionRecord(panelID: panelID, resource: resourceID)

        catalog.register(original)
        catalog.restore([record], workspaceID: UUID())
        #expect(catalog.pendingRestoredMachineIDs == Set(["reused"]))

        catalog.unregister(machine: machine)
        catalog.register(replacement)
        catalog.replaceResources([terminal(machine, "term_old")], on: machine, from: replacement)

        // The resource ID was reused, but the restored pane belonged to the
        // deleted machine instance and must not attach to the replacement.
        #expect(catalog.pendingRestoredMachineIDs.isEmpty)
        #expect(catalog.projection(forPanel: panelID) == nil)
    }

    @Test func `Unregistering a machine closes its display and browser panes but not terminals`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("m"))
        catalog.register(provider)
        let term = terminal(.cloud("m"), "term_1")
        let display = SurfaceResource(id: SurfaceResourceID(machine: .cloud("m"), kind: .display, key: "display:1"), title: "Desktop", detail: "noVNC", lifecycle: .running, agent: nil, remoteWorkspace: nil, port: 6901, url: nil)
        let browser = SurfaceResource(id: SurfaceResourceID(machine: .cloud("m"), kind: .browser, key: "port:3000"), title: ":3000", detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: nil, port: 3000, url: nil)
        catalog.replaceResources([term, display, browser], on: .cloud("m"))
        let termProjection = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split)).projection
        let displayProjection = try await catalog.project(display.id, into: .workspace(id: UUID(), placement: .split)).projection
        let browserProjection = try await catalog.project(browser.id, into: .workspace(id: UUID(), placement: .split)).projection

        catalog.unregister(machine: .cloud("m"))

        // The tokened gateway panes close with the machine (their URL decays into
        // the hosting provider's raw error page); the terminal pane stays.
        #expect(Set(provider.discardInvocations.map(\.panelID)) == [displayProjection.panelID, browserProjection.panelID])
        #expect(!provider.discardInvocations.map(\.panelID).contains(termProjection.panelID))
        #expect(catalog.snapshot.projections.isEmpty)
    }

    private func workspaceTerminal(_ machine: SurfaceMachineID, _ key: String, workspace: SurfaceRemoteWorkspace?) -> SurfaceResource {
        SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: key, detail: "/root", lifecycle: .running, agent: nil, remoteWorkspace: workspace, port: nil, url: nil)
    }

    @Test func `Delete workspace kills its viewed terminals first, spares the rest`() async throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)
        let doomedWorkspace = SurfaceRemoteWorkspace(id: "ws_1", name: "build", index: 0, focused: false)
        let otherWorkspace = SurfaceRemoteWorkspace(id: "ws_2", name: "main", index: 1, focused: true)
        catalog.replaceResources([
            workspaceTerminal(machine, "term_a", workspace: doomedWorkspace),
            workspaceTerminal(machine, "term_b", workspace: doomedWorkspace),
            workspaceTerminal(machine, "term_c", workspace: otherWorkspace),
            workspaceTerminal(machine, "term_pool", workspace: nil),
        ], on: machine)

        let closed = try await CloudTreeNodeActions.deleteWorkspaceAndTerminals(
            machine: machine, provider: provider, catalog: catalog, workspaceID: "ws_1"
        )

        // The delete contract, identical for the sidebar row and `vm.workspace_delete`:
        // every terminal viewed in the workspace dies, terminals elsewhere and pool
        // terminals survive, and the workspace closes only after its terminals.
        #expect(closed == 2)
        #expect(Set(provider.closedTerminals.map(\.key)) == ["term_a", "term_b"])
        #expect(provider.closedRemoteWorkspaces == ["ws_1"])
        #expect(provider.remoteMutationLog.last == "workspace:ws_1")
    }

    @Test func `Delete of an empty workspace closes it and kills nothing`() async throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)
        catalog.replaceResources([
            workspaceTerminal(machine, "term_c", workspace: SurfaceRemoteWorkspace(id: "ws_2", name: "main", index: 0, focused: true)),
        ], on: machine)

        let closed = try await CloudTreeNodeActions.deleteWorkspaceAndTerminals(
            machine: machine, provider: provider, catalog: catalog, workspaceID: "ws_empty"
        )

        #expect(closed == 0)
        #expect(provider.closedTerminals.isEmpty)
        #expect(provider.closedRemoteWorkspaces == ["ws_empty"])
    }

    @Test func `Cloud workspace rename updates every projection and rejects stale snapshots`() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)

        let original = SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true)
        let other = SurfaceRemoteWorkspace(id: "ws_other", name: "other", index: 1, focused: false)
        var terminal = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_main"),
            title: "shell",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: original,
            port: nil,
            url: nil
        )
        terminal.remoteViews = [SurfaceRemoteView(tabID: "tab_main", workspace: original)]
        var unrelated = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_other"),
            title: "other",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: other,
            port: nil,
            url: nil
        )
        unrelated.remoteViews = [SurfaceRemoteView(tabID: "tab_other", workspace: other)]
        let initialInfo = SurfaceMachineInfo(
            id: machine,
            name: "vivid-newt",
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
            remoteWorkspaces: [original, other]
        )
        let generation = "daemon-generation"
        #expect(catalog.replaceCloudResources(
            [terminal, unrelated],
            on: machine,
            info: initialInfo,
            cursor: CloudVMCursor(generation: generation, revision: 10)
        ))

        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: original.id,
            name: "Renamed"
        )
        let optimistic = catalog.snapshot
        #expect(optimistic.machines.first?.remoteWorkspaces?.first { $0.id == original.id }?.name == "Renamed")
        #expect(optimistic.resources.first { $0.id == terminal.id }?.remoteWorkspace?.name == "Renamed")
        #expect(optimistic.resources.first { $0.id == terminal.id }?.remoteViews?.first?.workspace.name == "Renamed")
        #expect(optimistic.resources.first { $0.id == unrelated.id }?.remoteWorkspace?.name == "other")

        let staleInfo = initialInfo
        var staleTerminal = terminal
        staleTerminal.remoteWorkspace = original
        staleTerminal.remoteViews = [SurfaceRemoteView(tabID: "tab_main", workspace: original)]
        #expect(!catalog.replaceCloudResources(
            [staleTerminal, unrelated],
            on: machine,
            info: staleInfo,
            cursor: CloudVMCursor(generation: generation, revision: 9)
        ))
        #expect(catalog.snapshot.resources.first { $0.id == terminal.id }?.remoteWorkspace?.name == "Renamed")

        catalog.commitCloudWorkspaceRename(
            token,
            receipt: CloudVMCursor(generation: generation, revision: 11)
        )
        var confirmedInfo = initialInfo
        let confirmed = SurfaceRemoteWorkspace(id: original.id, name: "Renamed", index: 0, focused: true)
        confirmedInfo.remoteWorkspaces = [confirmed, other]
        var confirmedTerminal = terminal
        confirmedTerminal.remoteWorkspace = confirmed
        confirmedTerminal.remoteViews = [SurfaceRemoteView(tabID: "tab_main", workspace: confirmed)]
        #expect(catalog.replaceCloudResources(
            [confirmedTerminal, unrelated],
            on: machine,
            info: confirmedInfo,
            cursor: CloudVMCursor(generation: generation, revision: 11)
        ))
        #expect(catalog.pendingCloudWorkspaceRenameName(machine: machine, workspaceID: original.id) == nil)
        #expect(!catalog.replaceCloudResources(
            [staleTerminal, unrelated],
            on: machine,
            info: staleInfo,
            cursor: CloudVMCursor(generation: generation, revision: 10)
        ))
        #expect(catalog.snapshot.resources.first { $0.id == terminal.id }?.remoteWorkspace?.name == "Renamed")
        // An equal-cursor payload must also be identical; a delayed response
        // with the old name cannot overwrite the confirmed rename.
        #expect(!catalog.replaceCloudResources(
            [staleTerminal, unrelated],
            on: machine,
            info: staleInfo,
            cursor: CloudVMCursor(generation: generation, revision: 11)
        ))
        #expect(catalog.snapshot.resources.first { $0.id == terminal.id }?.remoteWorkspace?.name == "Renamed")
    }

    @Test func `A cursorless machine update cannot restore a confirmed cloud workspace name`() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)
        let before = SurfaceRemoteWorkspace(id: "ws_main", name: "before", index: 0, focused: true)
        let after = SurfaceRemoteWorkspace(id: before.id, name: "after", index: 0, focused: true)
        var beforeResource = terminal(machine, "term_main")
        beforeResource.remoteWorkspace = before
        var afterResource = beforeResource
        afterResource.remoteWorkspace = after
        let beforeInfo = SurfaceMachineInfo(
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
            remoteWorkspaces: [before]
        )
        var afterInfo = beforeInfo
        afterInfo.remoteWorkspaces = [after]
        #expect(catalog.replaceCloudResources(
            [beforeResource],
            on: machine,
            info: beforeInfo,
            cursor: CloudVMCursor(generation: "g", revision: 1)
        ))
        #expect(catalog.replaceCloudResources(
            [afterResource],
            on: machine,
            info: afterInfo,
            cursor: CloudVMCursor(generation: "g", revision: 2)
        ))

        // A provider summary/status write has no cursor and may still carry its
        // pre-rename cached workspace value. It must not overwrite the accepted graph.
        catalog.updateMachine(beforeInfo, from: provider)
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "after")
    }

    @Test func `A stale equal-cursor snapshot after a rename receipt cannot poison reconciliation`() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        catalog.register(FakeProvider(machine: machine))
        let before = SurfaceRemoteWorkspace(id: "ws_main", name: "before", index: 0, focused: true)
        let after = SurfaceRemoteWorkspace(id: before.id, name: "after", index: 0, focused: true)
        var beforeResource = terminal(machine, "term_main")
        beforeResource.remoteWorkspace = before
        var afterResource = beforeResource
        afterResource.remoteWorkspace = after
        let beforeInfo = SurfaceMachineInfo(
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
            remoteWorkspaces: [before]
        )
        var afterInfo = beforeInfo
        afterInfo.remoteWorkspaces = [after]
        #expect(catalog.replaceCloudResources(
            [beforeResource],
            on: machine,
            info: beforeInfo,
            cursor: CloudVMCursor(generation: "g", revision: 1)
        ))
        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: before.id,
            name: "after"
        )
        catalog.commitCloudWorkspaceRename(
            token,
            receipt: CloudVMCursor(generation: "g", revision: 2)
        )

        // The first read at the receipt cursor is stale, but the optimistic overlay
        // keeps the UI correct. A later canonical read at that same cursor must still
        // be accepted and retire the intent.
        #expect(!catalog.replaceCloudResources(
            [beforeResource],
            on: machine,
            info: beforeInfo,
            cursor: CloudVMCursor(generation: "g", revision: 2)
        ))
        #expect(catalog.replaceCloudResources(
            [afterResource],
            on: machine,
            info: afterInfo,
            cursor: CloudVMCursor(generation: "g", revision: 2)
        ))
        #expect(catalog.pendingCloudWorkspaceRenameName(machine: machine, workspaceID: before.id) == nil)
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "after")
    }

    @Test func `An older cloud rename completion cannot roll back a newer intent`() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        catalog.register(FakeProvider(machine: machine))
        let workspace = SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true)
        let info = SurfaceMachineInfo(
            id: machine,
            name: "vivid-newt",
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
            remoteWorkspaces: [workspace]
        )
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term"),
            title: "shell",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: workspace,
            port: nil,
            url: nil
        )
        #expect(catalog.replaceCloudResources(
            [resource],
            on: machine,
            info: info,
            cursor: CloudVMCursor(generation: "g", revision: 1)
        ))
        let first = try catalog.beginCloudWorkspaceRename(machine: machine, workspaceID: workspace.id, name: "first")
        let second = try catalog.beginCloudWorkspaceRename(machine: machine, workspaceID: workspace.id, name: "second")
        catalog.rollbackCloudWorkspaceRename(first)
        #expect(catalog.pendingCloudWorkspaceRenameName(machine: machine, workspaceID: workspace.id) == "second")
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "second")
        catalog.rollbackCloudWorkspaceRename(second)
        #expect(catalog.pendingCloudWorkspaceRenameName(machine: machine, workspaceID: workspace.id) == nil)
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "main")
    }
}
