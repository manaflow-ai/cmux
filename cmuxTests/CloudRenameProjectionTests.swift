import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct CloudRenameProjectionTests {
    private enum ExpectedFailure: Error { case oldRequest }

    @Test("a renamed cloud graph updates every placement without renaming unrelated workspaces")
    func renamedGraphUpdatesEveryPlacement() throws {
        let machine = CmuxTuiSurfaceProviderTests.machine
        let catalog = SurfaceCatalog()
        var snapshot = CmuxTuiSurfaceProviderTests.sessionSnapshot
        snapshot["cursor"] = ["generation": "g", "revision": "10"]
        let before = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        var info = SurfaceMachineInfo(
            id: machine, name: machine.rawValue, status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        )
        info.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true),
            SurfaceRemoteWorkspace(id: "ws_api", name: "api", index: 1, focused: false),
        ]
        catalog.replaceCloudState(before, resources: CmuxTuiSnapshotParser.resources(from: before), info: info)
        snapshot["cursor"] = ["generation": "g", "revision": "11"]
        snapshot["workspaces"] = [
            ["id": "ws_main", "name": "Renamed", "focused": true],
            ["id": "ws_api", "name": "api", "focused": false],
        ]
        let after = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        info.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws_main", name: "Renamed", index: 0, focused: true),
            SurfaceRemoteWorkspace(id: "ws_api", name: "api", index: 1, focused: false),
        ]
        catalog.replaceCloudState(after, resources: CmuxTuiSnapshotParser.resources(from: after), info: info)
        let resources = catalog.snapshot.resources(on: machine)
        let build = try #require(resources.first { $0.id.key == "term_build" })
        #expect(build.remoteWorkspace?.name == "Renamed")
        #expect(build.remoteViews?.first { $0.tabID == "tab_1" }?.workspace.name == "Renamed")
        #expect(build.remoteViews?.first { $0.tabID == "tab_4" }?.workspace.name == "api")
        #expect(resources.first { $0.id.key == "term_shell" }?.remoteWorkspace?.name == "api")
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.first?.name == "Renamed")
        #expect(catalog.cloudStates[machine]?.cursor == after.cursor)
    }

    @Test("an older failed rename completion cannot clear a newer pending intent")
    func oldCompletionPreservesNewerIntent() async throws {
        let coordinator = CloudRenameCoordinator()
        let key = CloudRenameCoordinator.Key.workspace(machine: .cloud("vm-1"), id: "ws-1")
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let nextStarted = AsyncStream<Void>.makeStream()
        let nextRelease = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish(); release.continuation.finish()
            nextStarted.continuation.finish(); nextRelease.continuation.finish()
        }
        let first = coordinator.enqueue(key: key, pendingName: "first") {
            started.continuation.yield(())
            for await _ in release.stream.prefix(1) {}
            throw ExpectedFailure.oldRequest
        }
        for await _ in started.stream.prefix(1) {}
        let second = coordinator.enqueue(key: key, pendingName: "second") {
            nextStarted.continuation.yield(())
            for await _ in nextRelease.stream.prefix(1) {}
        }
        #expect(coordinator.pendingName(for: key) == "second")
        release.continuation.yield(())
        _ = try? await first.value
        for await _ in nextStarted.stream.prefix(1) {}
        #expect(coordinator.pendingName(for: key) == "second")
        nextRelease.continuation.yield(())
        try await second.value
        #expect(coordinator.pendingName(for: key) == nil)
    }
}
