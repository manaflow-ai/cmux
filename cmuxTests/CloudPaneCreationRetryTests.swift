import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud pane creation retry")
@MainActor
struct CloudPaneCreationRetryTests {
    @Test
    func aNewIntentDoesNotOrphanAnActiveRetry() async {
        let store = CloudPaneCreationFailureStore()
        let failed = CloudLinkFirstValue<Bool>()
        let retryStarted = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let returned = CloudLinkFirstValue<Bool>()
        let resource = Self.resource()
        var projects = 0
        var discarded = false
        store.run(
            machine: resource.machine,
            requestID: store.beginRequest(),
            create: { resource },
            project: { resource in
                projects += 1
                if projects == 1 { throw CloudDiagnosticFailure.network }
                retryStarted.resolve(true)
                _ = await release.result
                returned.resolve(true)
                return (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onStart: {},
            onFinish: { failed.resolve(true) },
            discardProjection: { _ in discarded = true }
        )
        _ = await failed.result
        store.retry()
        _ = await retryStarted.result
        _ = store.beginRequest()
        store.cancelAll()
        release.resolve(true)
        _ = await returned.result
        #expect(discarded)
    }

    @Test
    func inlineRetryProjectsTheExistingTerminal() async throws {
        let store = CloudPaneCreationFailureStore()
        let requestID = store.beginRequest()
        let completions = AsyncStream<Void>.makeStream()
        var completion = completions.stream.makeAsyncIterator()
        let resource = Self.resource()
        var creates = 0
        var projections = 0
        store.run(
            machine: resource.machine,
            requestID: requestID,
            create: { creates += 1; return resource },
            project: { resource in
                projections += 1
                if projections == 1 { throw CloudDiagnosticFailure.network }
                return (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onStart: {},
            onFinish: { completions.continuation.yield(()) },
            discardProjection: { _ in }
        )
        _ = await completion.next()
        #expect(store.failure != nil)
        #expect(store.canRetry)
        store.retry()
        _ = await completion.next()
        #expect(creates == 1)
        #expect(projections == 2)
        #expect(store.failure == nil)
        #expect(!store.canRetry)
    }

    @Test
    func workspaceTeardownCancelsPendingProjectionAndReleasesItsScope() async {
        let store = CloudPaneCreationFailureStore()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let createReturned = CloudLinkFirstValue<Bool>()
        let resource = Self.resource()
        var projections = 0
        var finished = 0
        store.run(
            machine: resource.machine,
            requestID: store.beginRequest(),
            create: {
                started.resolve(true)
                _ = await release.result
                createReturned.resolve(true)
                return resource
            },
            project: { resource in
                projections += 1
                return (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onStart: {},
            onFinish: { finished += 1 },
            discardProjection: { _ in }
        )
        _ = await started.result
        store.cancelAll()
        release.resolve(true)
        _ = await createReturned.result
        #expect(finished == 1)
        #expect(projections == 0)
        #expect(store.failure == nil)
        #expect(!store.canRetry)
    }

    private static func resource() -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("retry-fixture"), kind: .terminal, key: "term_created"),
            title: "", detail: nil, lifecycle: .launching, agent: nil,
            remoteWorkspace: nil, remoteViews: [], port: nil, url: nil
        )
    }
}
