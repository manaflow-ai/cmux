import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5832.
///
/// `VerticalTabsSidebar.body` used to rebuild ~5 O(N) lookup dictionaries plus
/// the render-item traversal on every observable tick that re-evaluated the
/// body — including ticks orthogonal to the inputs those structures depend on
/// (workspace title, status entries, unread counts, …). The fix memoizes them
/// in `SidebarWorkspaceListDerivedCache`, keyed on a fingerprint of the inputs
/// that actually matter. These tests assert the cache rebuilds once per relevant
/// change and *not* on unrelated workspace state churn.
@MainActor
final class SidebarWorkspaceListDerivedCacheTests: XCTestCase {

    private func makeManagerWithWorkspaces(_ count: Int) -> TabManager {
        let manager = TabManager()
        // TabManager seeds one workspace; add the rest.
        while manager.tabs.count < count {
            _ = manager.addWorkspace()
        }
        return manager
    }

    func testFirstCallBuildsDerivedStructures() {
        let manager = makeManagerWithWorkspaces(3)
        let cache = SidebarWorkspaceListDerivedCache()

        let derived = cache.derived(tabs: manager.tabs, workspaceGroups: manager.workspaceGroups)

        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(derived.tabIds, manager.tabs.map(\.id))
        XCTAssertEqual(derived.tabIndexById.count, 3)
        XCTAssertEqual(derived.workspaceById.count, 3)
        for (offset, tab) in manager.tabs.enumerated() {
            XCTAssertEqual(derived.tabIndexById[tab.id], offset)
            XCTAssertTrue(derived.workspaceById[tab.id] === tab)
        }
    }

    /// The core regression: an unrelated workspace state change (title) must NOT
    /// trigger a rebuild of the derived structures. Without memoization this
    /// rebuilds every call and `rebuildCount` climbs to 2.
    func testUnrelatedWorkspaceStateChangeDoesNotRebuild() {
        let manager = makeManagerWithWorkspaces(3)
        let cache = SidebarWorkspaceListDerivedCache()

        _ = cache.derived(tabs: manager.tabs, workspaceGroups: manager.workspaceGroups)
        XCTAssertEqual(cache.rebuildCount, 1)

        // Simulate an orthogonal observable tick: a workspace's title changes.
        // None of the cache's fingerprint inputs (ids, order, groupId, groups)
        // are affected, so the cache must serve the memoized value.
        manager.tabs[0].title = "changed-title"
        manager.tabs[1].customTitle = "custom"

        _ = cache.derived(tabs: manager.tabs, workspaceGroups: manager.workspaceGroups)
        XCTAssertEqual(
            cache.rebuildCount, 1,
            "An unrelated workspace state change must not rebuild the sidebar derived structures (#5832)"
        )
    }

    func testRepeatedIdenticalCallsDoNotRebuild() {
        let manager = makeManagerWithWorkspaces(4)
        let cache = SidebarWorkspaceListDerivedCache()

        for _ in 0..<10 {
            _ = cache.derived(tabs: manager.tabs, workspaceGroups: manager.workspaceGroups)
        }
        XCTAssertEqual(cache.rebuildCount, 1)
    }

    func testAddingWorkspaceRebuilds() {
        let manager = makeManagerWithWorkspaces(3)
        let cache = SidebarWorkspaceListDerivedCache()

        _ = cache.derived(tabs: manager.tabs, workspaceGroups: manager.workspaceGroups)
        XCTAssertEqual(cache.rebuildCount, 1)

        _ = manager.addWorkspace()

        let derived = cache.derived(tabs: manager.tabs, workspaceGroups: manager.workspaceGroups)
        XCTAssertEqual(cache.rebuildCount, 2)
        XCTAssertEqual(derived.tabIndexById.count, 4)
    }

    func testGroupIdChangeRebuilds() {
        let manager = makeManagerWithWorkspaces(2)
        let cache = SidebarWorkspaceListDerivedCache()

        _ = cache.derived(tabs: manager.tabs, workspaceGroups: manager.workspaceGroups)
        XCTAssertEqual(cache.rebuildCount, 1)

        // A grouping change mutates per-workspace `groupId` even when membership
        // and order are unchanged; the fingerprint must catch it.
        let newGroupId = UUID()
        manager.tabs[0].groupId = newGroupId

        _ = cache.derived(tabs: manager.tabs, workspaceGroups: manager.workspaceGroups)
        XCTAssertEqual(cache.rebuildCount, 2)
        XCTAssertEqual(cache.derived(tabs: manager.tabs, workspaceGroups: manager.workspaceGroups).rebuildSentinelGroupId(newGroupId), newGroupId)
        // Still only two rebuilds — the last identical call was memoized.
        XCTAssertEqual(cache.rebuildCount, 2)
    }
}

private extension SidebarWorkspaceListDerivedCache.Derived {
    /// Tiny helper to read back the mapped groupId for the assertion above
    /// without leaking dictionary-access noise into the test body.
    func rebuildSentinelGroupId(_ expected: UUID) -> UUID? {
        for (_, gid) in workspaceGroupIdByWorkspaceId where gid == expected {
            return gid
        }
        return nil
    }
}
