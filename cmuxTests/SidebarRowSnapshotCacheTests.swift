import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar snapshot lifetime")
struct SidebarRowSnapshotCacheTests {
    @Test func replacingMembershipAtTheSameCountReleasesRetiredSnapshot() {
        let cache = SidebarRowSnapshotCache()
        let retiredID = UUID()
        let replacementID = UUID()
        let snapshot = SidebarWorkspaceRowSuspensionTests.makeModel().snapshot
        cache.replace(with: [retiredID: snapshot])

        // A restore/reorder can replace membership without changing its count.
        cache.prune(keeping: [replacementID])
        #expect(cache.value(for: retiredID) == nil)
        cache.replace(with: [replacementID: snapshot])
        #expect(cache.value(for: replacementID) == snapshot)
    }

    @Test func repeatedWorkspaceReplacementDoesNotRetainHistoricalSnapshots() {
        let cache = SidebarRowSnapshotCache()
        let snapshot = SidebarWorkspaceRowSuspensionTests.makeModel().snapshot
        var liveID = UUID()
        cache.replace(with: [liveID: snapshot])
        var retiredIDs: [UUID] = []
        for _ in 0..<100 {
            retiredIDs.append(liveID)
            liveID = UUID()
            cache.prune(keeping: [liveID])
            cache.replace(with: [liveID: snapshot])
            #expect(cache.value(for: liveID) == snapshot)
        }
        #expect(retiredIDs.allSatisfy { cache.value(for: $0) == nil })
        cache.prune(keeping: [])
        #expect(cache.value(for: liveID) == nil)
    }
}
