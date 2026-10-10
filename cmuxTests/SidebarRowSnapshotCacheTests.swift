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

    @Test func clearingManualColorMatchingOriginRefreshesClearColorState() throws {
        let suiteName = "SidebarRowSnapshotCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = Workspace(title: "Color provenance", initialSurface: .cloudVMLoading)
        defer { workspace.teardownAllPanels() }
        let originColor = "#B1A2FA"
        let factory = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
            showsAgentActivity: false,
            originColorHex: originColor
        )
        let cache = SidebarRowSnapshotCache()
        workspace.customColor = originColor
        let manualSnapshot = factory.makeSnapshot()
        cache.reconcile(workspaceIds: [workspace.id], presentationKey: manualSnapshot.presentationKey) { _ in
            manualSnapshot
        }
        #expect(cache.value(for: workspace.id)?.hasManualCustomColor == true)

        workspace.customColor = nil
        let originSnapshot = factory.makeSnapshot()
        cache.reconcile(workspaceIds: [workspace.id], presentationKey: originSnapshot.presentationKey) { _ in
            originSnapshot
        }
        #expect(cache.value(for: workspace.id)?.customColorHex == originColor)
        #expect(cache.value(for: workspace.id)?.hasManualCustomColor == false)
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
