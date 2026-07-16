import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarWorkspaceSnapshotCacheOverlayTests {
    @Test
    func preservesCachedValuesAndBuildsOnlyMissingRows() {
        let cachedId = UUID()
        let secondCachedId = UUID()
        let insertedId = UUID()
        let requestedIds = [cachedId, secondCachedId, insertedId]
        var builtIds: [UUID] = []

        let values = SidebarWorkspaceSnapshotCacheOverlay(
            cachedValues: [
                cachedId: "cached-first",
                secondCachedId: "cached-second",
            ]
        ).values(for: requestedIds, identifiedBy: { $0 }) { workspaceId in
            builtIds.append(workspaceId)
            return "built-\(workspaceId)"
        }

        #expect(values[cachedId] == "cached-first")
        #expect(values[secondCachedId] == "cached-second")
        #expect(values[insertedId] == "built-\(insertedId)")
        #expect(builtIds == [insertedId])
        #expect(
            requestedIds.allSatisfy { values[$0] != nil },
            "Cold cache entries must not make initial or newly inserted sidebar rows disappear."
        )
    }
}
