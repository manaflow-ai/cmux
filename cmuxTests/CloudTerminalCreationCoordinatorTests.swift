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
    func retryDuringCreationDoesNotStartAnotherRemoteTerminal() async {
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let completed = CloudLinkFirstValue<Bool>()
        let resource = Self.resource(key: "term_created")
        var createCount = 0
        let coordinator = CloudTerminalCreationCoordinator(
            create: {
                createCount += 1
                started.resolve(true)
                // The remote mutation can commit even after local cancellation.
                _ = await release.result
                return resource
            },
            project: { resource in
                (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onFailure: { _ in },
            onSuccess: { completed.resolve(true) }
        )
        coordinator.start()
        _ = await started.result
        coordinator.retry()
        release.resolve(true)
        _ = await completed.result
        #expect(createCount == 1)
    }

    @Test @MainActor
    func materializationFailureKeepsTheCreatedTerminalForRetry() async {
        let resource = Self.resource(key: "term_1")
        var createCount = 0
        var projectCount = 0
        var shouldFail = true
        var starts = 0
        var failures = 0
        let projection = SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID())
        let coordinator = CloudTerminalCreationCoordinator(
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
            onStart: { starts += 1 },
            onFailure: { _ in failures += 1 },
            onSuccess: {}
        )
        coordinator.start()
        await Self.yieldUntil { failures == 1 }
        #expect(createCount == 1)
        #expect(projectCount == 1)

        coordinator.retry()
        await Self.yieldUntil { projectCount == 2 }
        #expect(createCount == 1)
        #expect(starts == 2)
    }

    @Test @MainActor
    func cancellationReportsOnceAndSkipsFailure() async {
        var cancelled = 0
        var failed = 0
        let coordinator = CloudTerminalCreationCoordinator(
            create: {
                try await Task.sleep(for: .seconds(5))
                return Self.resource(key: "term_slow")
            },
            project: { _ in throw CancellationError() },
            onFailure: { _ in failed += 1 },
            onCancel: { cancelled += 1 },
            onSuccess: {}
        )
        coordinator.start()
        coordinator.cancel()
        await Self.yieldUntil { cancelled >= 1 }
        #expect(cancelled == 1)
        #expect(failed == 0)
    }

    @Test @MainActor
    func cancellationDiscardsAProjectionCreatedByTheStaleOperation() async {
        let resource = Self.resource(key: "term_1")
        let projection = SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID())
        let startedStream = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var discarded = false
        let coordinator = CloudTerminalCreationCoordinator(
            create: { resource },
            project: { _ in
                startedStream.continuation.yield(())
                await withCheckedContinuation { continuation in
                    release = continuation
                }
                return (projection: projection, reused: false)
            },
            onFailure: { _ in },
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

    private static func resource(key: String) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("machine"), kind: .terminal, key: key),
            title: "", detail: nil, lifecycle: .launching, agent: nil,
            remoteWorkspace: nil, remoteViews: [], port: nil, url: nil
        )
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
