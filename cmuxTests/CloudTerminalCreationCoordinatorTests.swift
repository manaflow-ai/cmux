import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud terminal creation")
struct CloudTerminalCreationCoordinatorTests {
    @Test @MainActor
    func materializationFailureKeepsTheCreatedTerminalForRetry() async {
        let panel = CloudTerminalPendingPanel(
            workspaceId: UUID(),
            machine: .cloud("machine")
        )
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("machine"), kind: .terminal, key: "term_1"),
            title: "",
            detail: nil,
            lifecycle: .launching,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: [],
            port: nil,
            url: nil
        )
        var createCount = 0
        var projectCount = 0
        var shouldFail = true
        let projection = SurfaceProjection(
            resource: resource.id,
            workspaceID: UUID(),
            panelID: UUID()
        )
        let coordinator = CloudTerminalCreationCoordinator(
            panel: panel,
            create: {
                createCount += 1
                return resource
            },
            project: { _ in
                projectCount += 1
                if shouldFail {
                    shouldFail = false
                    throw SurfaceCatalogError.unavailable(resource.id, reason: "link restarting")
                }
                return (projection: projection, reused: false)
            },
            onSuccess: {}
        )
        panel.onRetry = { coordinator.retry() }
        coordinator.start()
        await Self.yieldUntil {
            if case .failed = panel.state.phase { return true }
            return false
        }
        #expect(createCount == 1)
        #expect(projectCount == 1)

        panel.retry()
        await Self.yieldUntil { projectCount == 2 }
        #expect(createCount == 1)
        #expect(panel.state.phase == .starting)
    }

    @Test @MainActor
    func closingPendingPanelCancelsTheOperation() async {
        let panel = CloudTerminalPendingPanel(
            workspaceId: UUID(),
            machine: .cloud("machine")
        )
        var cancelled = false
        panel.onCancel = { cancelled = true }
        panel.close()
        #expect(cancelled)
    }

    @Test @MainActor
    func cancellationDiscardsAProjectionCreatedByTheStaleOperation() async {
        let panel = CloudTerminalPendingPanel(
            workspaceId: UUID(),
            machine: .cloud("machine")
        )
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("machine"), kind: .terminal, key: "term_1"),
            title: "",
            detail: nil,
            lifecycle: .launching,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: [],
            port: nil,
            url: nil
        )
        let projection = SurfaceProjection(
            resource: resource.id,
            workspaceID: UUID(),
            panelID: UUID()
        )
        let startedStream = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var discarded = false
        let coordinator = CloudTerminalCreationCoordinator(
            panel: panel,
            create: { resource },
            project: { _ in
                startedStream.continuation.yield(())
                await withCheckedContinuation { continuation in
                    release = continuation
                }
                return (projection: projection, reused: false)
            },
            onSuccess: {},
            discardProjection: { _ in discarded = true }
        )

        coordinator.start()
        var iterator = startedStream.stream.makeAsyncIterator()
        _ = await iterator.next()
        coordinator.cancel()
        release?.resume()
        await Self.yieldUntil { discarded }

        #expect(discarded)
    }

    @MainActor
    private static func yieldUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }
}
