import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct CurrentWorkQueryServiceTests {
    @Test("Each read captures existing owners once and preserves unavailable sessions")
    func ownerCaptureIsBoundedAndReadOnly() {
        let catalog = SurfaceCatalog()
        var workspaceReads = 0, sessionReads = 0, unreadReads = 0, surfaceUnreadReads = 0
        let query = CurrentWorkQueryService(
            catalog: catalog,
            workspaceOwners: { ids in
                workspaceReads += 1
                #expect(ids.isEmpty)
                return [:]
            },
            agentRecords: { sessionReads += 1; return nil },
            unread: { unreadReads += 1; return .init() },
            unreadSurfaces: { surfaceUnreadReads += 1; return [] },
            now: { Date(timeIntervalSince1970: 1_789_862_400) }
        )
        let snapshot = query.read()
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.ownerAvailability["agent_sessions"] == "unavailable")
        #expect(workspaceReads == 1)
        #expect(sessionReads == 1)
        #expect(unreadReads == 1)
        #expect(surfaceUnreadReads == 1)
        #expect(catalog.export.catalog == .empty)
    }

    @Test("Successive reads derive from current catalog owners rather than a second store")
    func laterReadUsesUpdatedOwner() throws {
        let catalog = SurfaceCatalog()
        let query = CurrentWorkQueryService(catalog: catalog, workspaceOwners: { _ in [:] }, agentRecords: { [] },
                                           unread: { .init() }, unreadSurfaces: { [] })
        var resource = SurfaceResource(id: .init(machine: .local, kind: .terminal, key: "example"), title: "first", detail: nil,
                                       lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
        catalog.upsert(resource)
        let first = try #require(query.read().items.first)
        resource.title = "second"
        catalog.upsert(resource)
        let second = try #require(query.read().items.first)
        #expect(first.label == "first")
        #expect(second.label == "second")
        #expect(first.resourceRef == second.resourceRef)
        #expect(query.read().ownerAvailability["agent_sessions"] == "available")
    }
}
