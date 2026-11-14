import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Wiring of the session priority rank into a window's TabManager: user
/// moves record, cmux's automatic moves never do, new workspaces join at the
/// end, pinned workspaces count first, and the rank survives session restore.
///
/// Serialized: tests that swap a `SessionPriorityCoordinatorHook` closure put back the one the
/// app installed.
@MainActor
@Suite(.serialized)
struct TabManagerSessionPriorityReorderTests {
    /// A manager with four unpinned workspaces in sidebar order `a b c d`.
    private struct Fixture {
        let manager: TabManager
        let a: UUID
        let b: UUID
        let c: UUID
        let d: UUID
    }

    private func makeFixture() throws -> Fixture {
        let manager = TabManager()
        let first = try #require(manager.tabs.first)
        let second = try #require(manager.addWorkspaceIfActive(select: false, placementOverride: .end))
        let third = try #require(manager.addWorkspaceIfActive(select: false, placementOverride: .end))
        let fourth = try #require(manager.addWorkspaceIfActive(select: false, placementOverride: .end))
        let fixture = Fixture(manager: manager, a: first.id, b: second.id, c: third.id, d: fourth.id)
        try #require(manager.tabs.map(\.id) == [fixture.a, fixture.b, fixture.c, fixture.d])
        try #require(manager.sessionPriorityEffectiveOrder == [fixture.a, fixture.b, fixture.c, fixture.d])
        return fixture
    }

    // MARK: - User moves record

    @Test func dragRecordsTheMove() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }

        #expect(manager.reorderSidebarWorkspace(tabId: fixture.d, toIndex: 0, isDragOperation: true))

        #expect(manager.tabs.map(\.id) == [fixture.d, fixture.a, fixture.b, fixture.c])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.d, fixture.a, fixture.b, fixture.c])
    }

    @Test func moveToTopRecords() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }

        manager.moveTabToTop(fixture.c)

        #expect(manager.sessionPriorityEffectiveOrder == [fixture.c, fixture.a, fixture.b, fixture.d])
    }

    /// A notification bump shows d first under the pinned a while it ranks last. Move to Top,
    /// which leaves the list as it is, affirms d's place (ruling R24).
    @Test func moveToTopOfTheWorkspaceAlreadyAtTheTopPromotesIt() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        manager.setPinned(try #require(manager.workspacesById[fixture.a]), pinned: true)
        manager.moveTabToTopForNotification(fixture.d)
        try #require(manager.tabs.map(\.id) == [fixture.a, fixture.d, fixture.b, fixture.c])
        try #require(manager.sessionPriorityEffectiveOrder == [fixture.a, fixture.b, fixture.c, fixture.d])
        let installed = SessionPriorityCoordinatorHook.userDidReorder
        defer { SessionPriorityCoordinatorHook.userDidReorder = installed }
        var reports = 0
        SessionPriorityCoordinatorHook.userDidReorder = { _ in reports += 1 }

        manager.moveTabToTop(fixture.d)

        #expect(manager.tabs.map(\.id) == [fixture.a, fixture.d, fixture.b, fixture.c])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.a, fixture.d, fixture.b, fixture.c])
        #expect(reports == 1)
    }

    /// Move Down on the bottom workspace is clamped and still handled. The user asked to go
    /// down, so it does not promote d above c, which a bump showed first.
    @Test func moveDownAtTheBottomDoesNotPromote() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        manager.moveTabToTopForNotification(fixture.c)
        try #require(manager.tabs.map(\.id) == [fixture.c, fixture.a, fixture.b, fixture.d])

        #expect(manager.reorderWorkspace(tabId: fixture.d, by: 1))

        #expect(manager.tabs.map(\.id) == [fixture.c, fixture.a, fixture.b, fixture.d])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.a, fixture.b, fixture.c, fixture.d])
    }

    /// `reorder-workspace --index 5` on the bottom workspace: the socket moves it to the clamped
    /// plan index, its current one, but the user asked to go past the end, so d is not promoted
    /// above c, which a bump showed first (ruling R30).
    @Test func indexPastTheEndOnTheBottomWorkspaceDoesNotPromote() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        manager.moveTabToTopForNotification(fixture.c)
        try #require(manager.tabs.map(\.id) == [fixture.c, fixture.a, fixture.b, fixture.d])
        let clamped = try #require(manager.workspaceReorderPlan(tabId: fixture.d, toIndex: 5)?.toIndex)
        try #require(clamped == 3)

        #expect(manager.reorderWorkspace(tabId: fixture.d, toIndex: clamped, requestedIndex: 5))

        #expect(manager.tabs.map(\.id) == [fixture.c, fixture.a, fixture.b, fixture.d])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.a, fixture.b, fixture.c, fixture.d])
    }

    /// Move Up on the top workspace is clamped too; it asked to go up, so it affirms the place.
    @Test func moveUpAtTheTopAffirmsThePlace() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        manager.moveTabToTopForNotification(fixture.d)
        try #require(manager.tabs.map(\.id) == [fixture.d, fixture.a, fixture.b, fixture.c])

        #expect(manager.reorderWorkspace(tabId: fixture.d, by: -1))

        #expect(manager.sessionPriorityEffectiveOrder == [fixture.d, fixture.a, fixture.b, fixture.c])
    }

    /// The sidebar menu's Move to Top of a selection already at the top affirms it the same way.
    @Test func moveSelectionToTopThatLeavesTheOrderAffirmsIt() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        manager.moveTabToTopForNotification(fixture.d)
        manager.moveTabToTopForNotification(fixture.c)
        try #require(manager.tabs.map(\.id) == [fixture.c, fixture.d, fixture.a, fixture.b])

        manager.moveTabsToTop([fixture.c, fixture.d])

        #expect(manager.tabs.map(\.id) == [fixture.c, fixture.d, fixture.a, fixture.b])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.c, fixture.d, fixture.a, fixture.b])
    }

    @Test func batchReorderRecordsTheListedOrder() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        let ordered = [fixture.d, fixture.c, fixture.b, fixture.a]

        let result = manager.reorderWorkspaces(orderedWorkspaceIds: ordered)

        guard case .success = result else {
            Issue.record("batch reorder failed: \(result)")
            return
        }
        #expect(manager.sessionPriorityEffectiveOrder == ordered)
    }

    /// The sidebar menu's and command palette's "Move to Top" moves the whole selection.
    @Test func moveSelectionToTopRecords() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        let installed = SessionPriorityCoordinatorHook.userDidReorder
        defer { SessionPriorityCoordinatorHook.userDidReorder = installed }
        var reports = 0
        SessionPriorityCoordinatorHook.userDidReorder = { _ in reports += 1 }

        manager.moveTabsToTop([fixture.c, fixture.d])

        #expect(manager.tabs.map(\.id) == [fixture.c, fixture.d, fixture.a, fixture.b])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.c, fixture.d, fixture.a, fixture.b])
        #expect(reports == 1)
    }

    /// Dragging a multi-row selection records every moved workspace.
    @Test func multiSelectionDragRecords() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        let installed = SessionPriorityCoordinatorHook.userDidReorder
        defer { SessionPriorityCoordinatorHook.userDidReorder = installed }
        var reports = 0
        SessionPriorityCoordinatorHook.userDidReorder = { _ in reports += 1 }

        #expect(manager.reorderSidebarWorkspaces(
            tabIds: [fixture.c, fixture.d],
            draggedTabId: fixture.d,
            toIndex: 0
        ))

        #expect(manager.tabs.map(\.id) == [fixture.c, fixture.d, fixture.a, fixture.b])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.c, fixture.d, fixture.a, fixture.b])
        #expect(reports == 1)
    }

    @Test func userMoveCallsTheCoordinatorHook() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        let previousHook = SessionPriorityCoordinatorHook.userDidReorder
        defer { SessionPriorityCoordinatorHook.userDidReorder = previousHook }
        var reportedManagers: [ObjectIdentifier] = []
        SessionPriorityCoordinatorHook.userDidReorder = { reported in
            reportedManagers.append(ObjectIdentifier(reported))
        }

        manager.moveTabToTopForNotification(fixture.d)
        #expect(reportedManagers.isEmpty)

        manager.moveTabToTop(fixture.c)
        #expect(reportedManagers == [ObjectIdentifier(manager)])
    }

    // MARK: - Automatic moves never record

    @Test func notificationBumpDoesNotChangeTheRank() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }

        manager.moveTabToTopForNotification(fixture.d)

        #expect(manager.tabs.map(\.id) == [fixture.d, fixture.a, fixture.b, fixture.c])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.a, fixture.b, fixture.c, fixture.d])
    }

    @Test func userMoveAfterBumpKeepsBumpedWorkspaceInPlace() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }

        manager.moveTabToTopForNotification(fixture.d)
        #expect(manager.reorderWorkspace(tabId: fixture.b, by: -1))

        #expect(manager.tabs.map(\.id) == [fixture.d, fixture.b, fixture.a, fixture.c])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.b, fixture.a, fixture.c, fixture.d])
    }

    @Test func automaticOriginDoesNotRecord() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }

        #expect(manager.reorderWorkspace(tabId: fixture.d, toIndex: 0, origin: .automatic))

        #expect(manager.tabs.map(\.id) == [fixture.d, fixture.a, fixture.b, fixture.c])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.a, fixture.b, fixture.c, fixture.d])
    }

    @Test func promptSubmitBumpDoesNotRecord() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }

        let outcome = try #require(
            manager.handlePromptSubmit(workspaceId: fixture.d, message: "go", iMessageModeEnabled: true)
        )

        #expect(outcome.reordered)
        #expect(manager.tabs.map(\.id) == [fixture.d, fixture.a, fixture.b, fixture.c])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.a, fixture.b, fixture.c, fixture.d])
    }

    @Test func batchReorderDryRunDoesNotRecord() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }

        let result = manager.reorderWorkspaces(
            orderedWorkspaceIds: [fixture.d, fixture.c, fixture.b, fixture.a],
            dryRun: true
        )

        guard case .success = result else {
            Issue.record("dry-run batch reorder failed: \(result)")
            return
        }
        #expect(manager.tabs.map(\.id) == [fixture.a, fixture.b, fixture.c, fixture.d])
        #expect(manager.sessionPriorityEffectiveOrder == [fixture.a, fixture.b, fixture.c, fixture.d])
    }

    // MARK: - Membership and pinning

    @Test func newWorkspaceJoinsAtTheEnd() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }

        let fifth = try #require(manager.addWorkspaceIfActive(select: false, placementOverride: .top))
        let sixth = try #require(manager.addWorkspaceIfActive(select: false, placementOverride: .top))

        #expect(manager.tabs.map(\.id) == [sixth.id, fifth.id, fixture.a, fixture.b, fixture.c, fixture.d])
        #expect(
            manager.sessionPriorityEffectiveOrder
                == [fixture.a, fixture.b, fixture.c, fixture.d, fifth.id, sixth.id]
        )
    }

    @Test func pinnedWorkspacesComeFirst() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        let pinned = try #require(manager.workspacesById[fixture.c])

        manager.setPinned(pinned, pinned: true)

        #expect(manager.sessionPriorityEffectiveOrder == [fixture.c, fixture.a, fixture.b, fixture.d])
    }

    // MARK: - Persistence

    @Test func rankRoundTripsThroughSessionSnapshot() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager
        defer { manager.closeWorkspacesForTesting() }
        // User puts c first, then a notification bumps d to the top: the
        // sidebar reads d c a b while the rank stays c a b d.
        manager.moveTabToTop(fixture.c)
        manager.moveTabToTopForNotification(fixture.d)
        try #require(manager.tabs.map(\.id) == [fixture.d, fixture.c, fixture.a, fixture.b])
        let expected = [fixture.c, fixture.a, fixture.b, fixture.d]
        try #require(manager.sessionPriorityEffectiveOrder == expected)
        let expectedStableIds = expected.compactMap { manager.workspacesById[$0]?.stableId }
        try #require(expectedStableIds.count == expected.count)

        let encoded = try JSONEncoder().encode(manager.sessionSnapshot(includeScrollback: false))
        let snapshot = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: encoded)

        let sameIds = TabManager()
        defer { sameIds.closeWorkspacesForTesting() }
        sameIds.restoreSessionSnapshot(snapshot)
        #expect(sameIds.tabs.map(\.id) == [fixture.d, fixture.c, fixture.a, fixture.b])
        #expect(sameIds.sessionPriorityEffectiveOrder == expected)

        let freshIds = TabManager()
        defer { freshIds.closeWorkspacesForTesting() }
        freshIds.restoreSessionSnapshot(snapshot, excludingWorkspaceIds: Set(expected))
        #expect(Set(freshIds.tabs.map(\.id)).isDisjoint(with: expected))
        let restoredStableIds = freshIds.sessionPriorityEffectiveOrder.compactMap {
            freshIds.workspacesById[$0]?.stableId
        }
        #expect(restoredStableIds == expectedStableIds)
    }
}
