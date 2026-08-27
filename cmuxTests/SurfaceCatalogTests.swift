import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The surface catalog: one identity per resource, zero or more projections, one open path.
@MainActor
final class SurfaceCatalogTests: XCTestCase {
    @MainActor
    private final class MaterializeGate {
        private(set) var entered = false
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?

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
                releaseContinuation = continuation
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private final class FakeProvider: SurfaceProvider {
        let machine: SurfaceMachineID
        var info: SurfaceMachineInfo
        var materialized: [(SurfaceResourceID, SurfaceDestination)] = []
        var ended: [SurfaceProjection] = []
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
            return SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: panelID)
        }

        func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
            SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_new"), title: name ?? "shell", detail: cwd, lifecycle: .launching, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
        }

        func projectionDidEnd(_ projection: SurfaceProjection) { ended.append(projection) }
    }

    private func terminal(_ machine: SurfaceMachineID, _ key: String, title: String = "shell") -> SurfaceResource {
        SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: "/root", lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
    }

    func testResourceIDRoundTripsThroughTheWireForm() {
        let id = SurfaceResourceID(machine: .cloud("vivid-newt"), kind: .browser, key: "port:8000/https://x.y/z")
        XCTAssertEqual(id.rawValue, "vivid-newt/browser/port:8000/https://x.y/z")
        XCTAssertEqual(SurfaceResourceID(rawValue: id.rawValue), id)
        XCTAssertEqual(SurfaceResourceID(rawValue: "local/terminal/ABC")?.machine, .local)
        XCTAssertNil(SurfaceResourceID(rawValue: "local/nope/x"))
        XCTAssertNil(SurfaceResourceID(rawValue: "local/terminal/"))
    }

    func testProjectMaterializesOnceAndReusesTheOpenPane() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("vivid-newt"))
        catalog.register(provider)
        let term = terminal(.cloud("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .cloud("vivid-newt"))
        var focused: [SurfaceProjection] = []
        catalog.focusProjection = { focused.append($0) }

        let ws = UUID()
        let first = try await catalog.project(term.id, into: .workspace(id: ws, placement: .split))
        XCTAssertFalse(first.reused)
        XCTAssertEqual(provider.materialized.count, 1)
        XCTAssertEqual(catalog.projections(of: term.id).count, 1)
        XCTAssertTrue(catalog.snapshot.isOpen(term.id))

        let second = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .tab))
        XCTAssertTrue(second.reused)
        XCTAssertEqual(second.projection, first.projection)
        XCTAssertEqual(provider.materialized.count, 1, "reuse must not materialize a second pane")
        XCTAssertEqual(focused, [first.projection])

        let third = try await catalog.project(term.id, into: .workspace(id: ws, placement: .split), reuseExisting: false)
        XCTAssertFalse(third.reused)
        XCTAssertEqual(catalog.projections(of: term.id).count, 2)
    }

    func testConcurrentReuseWaitsForTheInFlightMaterialization() async throws {
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

        let secondStarted = BoolBox()
        let second = Task { @MainActor in
            secondStarted.value = true
            return try await catalog.project(term.id, into: destination)
        }
        while !secondStarted.value { await Task.yield() }
        XCTAssertEqual(provider.materialized.count, 1, "a concurrent reuse must share the pending provider call")

        gate.release()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertFalse(firstResult.reused)
        XCTAssertTrue(secondResult.reused)
        XCTAssertEqual(firstResult.projection, secondResult.projection)
        XCTAssertEqual(catalog.projections(of: term.id).count, 1)
    }

    func testUnregisteringACancelsInFlightMaterialization() async throws {
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

        do {
            _ = try await project.value
            XCTFail("an unregistered machine must not record a completed projection")
        } catch let error as SurfaceCatalogError {
            XCTAssertEqual(error, .unknownResource(term.id))
        }
        XCTAssertTrue(catalog.projections.isEmpty)
    }

    func testEndingAProjectionKeepsTheRemoteResourceAndTellsTheProvider() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("m"))
        catalog.register(provider)
        let term = terminal(.cloud("m"), "term_1")
        catalog.replaceResources([term], on: .cloud("m"))
        let projection = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split)).projection

        catalog.endProjections(panelID: projection.panelID)
        XCTAssertTrue(catalog.projections(of: term.id).isEmpty)
        XCTAssertNotNil(catalog.snapshot.resources.first { $0.id == term.id }, "closing a pane never destroys a remote resource")
        XCTAssertEqual(provider.ended, [projection])
    }

    func testMovingAPaneMovesItsProjection() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .local)
        catalog.register(provider)
        let term = terminal(.local, "ABC")
        catalog.replaceResources([term], on: .local)
        let projection = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split)).projection
        let other = UUID()
        catalog.moveProjections(panelID: projection.panelID, to: other)
        XCTAssertEqual(catalog.projection(forPanel: projection.panelID)?.workspaceID, other)
    }

    func testRestoredProjectionsResolveWhenTheProviderReportsTheResource() {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("m"))
        catalog.register(provider)
        let ws = UUID(), panel = UUID()
        let id = SurfaceResourceID(machine: .cloud("m"), kind: .terminal, key: "term_9")
        catalog.restore([SurfaceProjectionRecord(panelID: panel, resource: id)], workspaceID: ws)
        XCTAssertFalse(catalog.snapshot.isOpen(id), "unknown until the link reports it")

        catalog.replaceResources([terminal(.cloud("m"), "term_9")], on: .cloud("m"))
        XCTAssertEqual(catalog.projection(forPanel: panel), SurfaceProjection(resource: id, workspaceID: ws, panelID: panel))
        XCTAssertEqual(catalog.projectionRecords(forWorkspace: ws), [SurfaceProjectionRecord(panelID: panel, resource: id)])
    }

    func testSnapshotOrdersLocalFirstThenByNameAndWorkspaceIndex() {
        let catalog = SurfaceCatalog()
        catalog.register(FakeProvider(machine: .cloud("zeta")))
        catalog.register(FakeProvider(machine: .cloud("alpha")))
        catalog.register(FakeProvider(machine: .local))
        var t1 = terminal(.cloud("alpha"), "term_b"); t1.remoteWorkspace = SurfaceRemoteWorkspace(id: "ws_1", name: "1", index: 1, focused: false)
        var t0 = terminal(.cloud("alpha"), "term_a"); t0.remoteWorkspace = SurfaceRemoteWorkspace(id: "ws_0", name: "0", index: 0, focused: true)
        catalog.replaceResources([t1, t0], on: .cloud("alpha"))
        let snapshot = catalog.snapshot
        XCTAssertEqual(snapshot.machines.map { $0.id }, [.local, .cloud("alpha"), .cloud("zeta")])
        XCTAssertEqual(snapshot.resources(on: .cloud("alpha")).map { $0.id.key }, ["term_a", "term_b"])
    }

    func testUnregisteringAMachineDropsItsResourcesAndProjections() async throws {
        let catalog = SurfaceCatalog()
        let provider = FakeProvider(machine: .cloud("m"))
        catalog.register(provider)
        let term = terminal(.cloud("m"), "term_1")
        catalog.replaceResources([term], on: .cloud("m"))
        _ = try await catalog.project(term.id, into: .workspace(id: UUID(), placement: .split))
        catalog.unregister(machine: .cloud("m"))
        XCTAssertTrue(catalog.snapshot.resources.isEmpty)
        XCTAssertTrue(catalog.snapshot.projections.isEmpty)
        XCTAssertNil(catalog.provider(for: .cloud("m")))
    }
}

@MainActor
private final class BoolBox {
    var value = false
}
