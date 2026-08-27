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
            lock.lock()
            sleepCount += 1
            let count = sleepCount
            lock.unlock()
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
        var onDiscard: ((SurfaceProjection) -> Void)?
        var onMaterialize: (() -> Void)?
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

        func projectionDidEnd(_ projection: SurfaceProjection) { ended.append(projection) }

        func discardMaterialization(_ projection: SurfaceProjection) {
            discarded.append(projection)
            onDiscard?(projection)
        }
    }

    private func terminal(_ machine: SurfaceMachineID, _ key: String, title: String = "shell") -> SurfaceResource {
        SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: "/root", lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
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
        catalog.register(provider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))

        var project: Task<SurfaceProjectionMaterialization.Result, any Error>?
        provider.onMaterialize = { project?.cancel() }
        let task = Task { @MainActor in
            try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        }
        project = task

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        provider.onMaterialize = nil
        #expect(catalog.projections.isEmpty)
        #expect(provider.discarded.count == 1)
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

    @Test func `Tracked materialization capacity bounds permanently detached work`() async throws {
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
        #expect(replacementProvider.materialized.isEmpty)
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

    @Test func `Unregistering a machine drops its resources and projections`() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("m"))
        catalog.register(provider)
        let term = terminal(.cloud("m"), "term_1")
        catalog.replaceResources([term], on: .cloud("m"))
        _ = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        catalog.unregister(machine: .cloud("m"))
        #expect(catalog.snapshot.resources.isEmpty)
        #expect(catalog.snapshot.projections.isEmpty)
        #expect(catalog.provider(for: .cloud("m")) == nil)
    }
}
