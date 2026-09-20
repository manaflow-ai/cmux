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

    @Test("A lost creation reply replays its receipt rather than allocating another display")
    func creationRetryKeepsRequestIdentity() async throws {
        var creates: [String] = []
        let service = CloudDisplayCoordinator { command, _ in
            if command.contains(" list") { return .init(exitCode: 0, stdout: initial, stderr: "") }
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
            if command.contains(" list") { return .init(exitCode: 0, stdout: initial, stderr: "") }
            started.resolve(true)
            _ = await response.result
            return .init(exitCode: 0, stdout: created, stderr: "")
        }
        await service.refresh()
        let operation = Task { try await service.create() }
        _ = await started.result
        service.stop()
        response.resolve(true)
        do { _ = try await operation.value; Issue.record("Retired creation succeeded") } catch {}
        #expect(!service.canCreate)
        #expect(service.snapshot?.displays.count == 1)
    }

    @Test("Unsupported images never expose a fake creation action")
    func unsupportedGuest() async {
        let service = CloudDisplayCoordinator { _, _ in .init(exitCode: 127, stdout: "", stderr: "missing") }
        await service.refresh()
        #expect(!service.canCreate && service.snapshot == nil)
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

    private func decode(_ raw: String) throws -> CloudGuestDisplaySnapshot {
        try CloudGuestDisplaySnapshot(data: Data(raw.utf8))
    }
}
