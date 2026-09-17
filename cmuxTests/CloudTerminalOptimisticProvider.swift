import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Suspends authoritative creates so tests can inspect the immediate local layout.
@MainActor
final class CloudTerminalOptimisticProvider: SurfaceProvider, SurfaceLayoutTerminalCreating {
    let machine: SurfaceMachineID
    let info: SurfaceMachineInfo
    let arrivals = AsyncStream<Void>.makeStream()
    private(set) var anchors: [String?] = []
    private(set) var directions: [SurfaceSplitDirection?] = []
    private(set) var projected = 0
    var failNextProjection = false
    private var requests: [CheckedContinuation<SurfaceResource, Error>] = []

    init(machine: SurfaceMachineID) {
        self.machine = machine
        info = SurfaceMachineInfo(
            id: machine, name: "fixture", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        )
    }

    func refresh() async {}
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        try await createTerminal(nearTabID: "sidebar", splitDirection: nil)
    }
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource {
        anchors.append(nearTabID)
        directions.append(splitDirection)
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            arrivals.continuation.yield(())
        }
    }
    func acceptNext() {
        guard !requests.isEmpty else { return }
        let number = anchors.count
        let workspace = SurfaceRemoteWorkspace(id: "ws", name: "fixture", index: 0, focused: true)
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term-\(number)"),
            title: "terminal", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: workspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab-\(number)", workspace: workspace)],
            port: nil, url: nil
        )
        SurfaceCatalog.shared.upsert(resource, from: self)
        requests.removeFirst().resume(returning: resource)
    }
    func cancelRequests() {
        let pending = requests
        requests.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
        arrivals.continuation.finish()
    }
    func rejectNext() {
        guard !requests.isEmpty else { return }
        requests.removeFirst().resume(throwing: SurfaceCatalogError.noProvider(machine))
    }
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        if failNextProjection {
            failNextProjection = false
            throw SurfaceCatalogError.unavailable(resource.id, reason: "fixture projection failed")
        }
        let pane = try SurfacePaneFactory.makeCloudManualMirrorPane(
            at: destination, focus: focus, onInput: { _ in }, onResize: { _ in },
            onRuntimeReady: {}, onFocus: {}
        )
        projected += 1
        return SurfaceProjection(resource: resource.id, workspaceID: pane.workspaceID, panelID: pane.panelID)
    }
    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination, focus: Bool, adopting reservation: CloudTerminalPaneReservation?) async throws -> SurfaceProjection {
        guard let reservation else { return try await materialize(resource, at: destination, focus: focus) }
        if failNextProjection {
            failNextProjection = false
            throw SurfaceCatalogError.unavailable(resource.id, reason: "fixture projection failed")
        }
        projected += 1
        return SurfaceProjection(resource: resource.id, workspaceID: reservation.workspaceID, panelID: reservation.panelID)
    }
    func projectionDidEnd(_ projection: SurfaceProjection) {}
}
