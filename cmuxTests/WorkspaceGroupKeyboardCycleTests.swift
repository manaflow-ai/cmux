import Foundation
import Testing

import CmuxFoundation
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace group keyboard cycling", .serialized)
struct WorkspaceGroupKeyboardCycleTests {

    private func makeTabManager() -> TabManager {
        let suiteName = "cmux.workspace-group-keyboard-cycle-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        return manager
    }

    private func select(_ workspaceId: UUID, in manager: TabManager) throws {
        manager.selectWorkspace(try #require(manager.tabs.first { $0.id == workspaceId }))
    }

    /// One ungrouped workspace plus a group with one member.
    private func makeGroupedFixture() throws -> (TabManager, UUID, UUID, UUID, UUID) {
        let manager = makeTabManager()
        let ungroupedId = try #require(manager.selectedTabId)
        let member = manager.addTab(select: false)
        let groupId = try #require(manager.createWorkspaceGroup(
            name: "Grouped",
            childWorkspaceIds: [member.id]
        ))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        return (manager, ungroupedId, groupId, group.anchorWorkspaceId, member.id)
    }

    @Test func collapsedGroupIsASingleStopAndStaysCollapsed() throws {
        let (manager, ungroupedId, groupId, anchorId, _) = try makeGroupedFixture()
        manager.setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: true)
        try select(ungroupedId, in: manager)

        manager.selectNextTab()
        #expect(manager.selectedTabId == anchorId)

        manager.selectNextTab()
        #expect(manager.selectedTabId == ungroupedId)

        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        #expect(group.isCollapsed)
    }

    @Test func expandedGroupTraversesItsMembers() throws {
        let (manager, ungroupedId, _, anchorId, memberId) = try makeGroupedFixture()
        try select(ungroupedId, in: manager)

        manager.selectNextTab()
        #expect(manager.selectedTabId == anchorId)

        manager.selectNextTab()
        #expect(manager.selectedTabId == memberId)

        manager.selectNextTab()
        #expect(manager.selectedTabId == ungroupedId)
    }

    @Test func previousDirectionTraversesExpandedMembersInReverse() throws {
        // Three visible stops, so previous is distinguishable from next.
        let (manager, ungroupedId, _, anchorId, memberId) = try makeGroupedFixture()
        try select(ungroupedId, in: manager)

        manager.selectPreviousTab()
        #expect(manager.selectedTabId == memberId)

        manager.selectPreviousTab()
        #expect(manager.selectedTabId == anchorId)

        manager.selectPreviousTab()
        #expect(manager.selectedTabId == ungroupedId)
    }

    @Test func previousDirectionSkipsHiddenMembersOfACollapsedGroup() throws {
        let (manager, ungroupedId, groupId, anchorId, _) = try makeGroupedFixture()
        manager.setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: true)
        try select(ungroupedId, in: manager)

        manager.selectPreviousTab()
        #expect(manager.selectedTabId == anchorId)

        manager.selectPreviousTab()
        #expect(manager.selectedTabId == ungroupedId)

        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        #expect(group.isCollapsed)
    }

    @Test func hiddenSelectedMemberStepsRelativeToItsGroupHeader() throws {
        let (manager, ungroupedId, groupId, _, memberId) = try makeGroupedFixture()
        try select(memberId, in: manager)
        // The direct setter preserves focus, so the selected row is hidden.
        manager.setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: true)
        #expect(manager.selectedTabId == memberId)

        manager.selectNextTab()
        #expect(manager.selectedTabId == ungroupedId)

        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        #expect(group.isCollapsed)
    }

    @Test func singleVisibleStopKeepsSelection() throws {
        let manager = makeTabManager()
        let onlyId = try #require(manager.selectedTabId)

        manager.selectNextTab()
        #expect(manager.selectedTabId == onlyId)

        manager.selectPreviousTab()
        #expect(manager.selectedTabId == onlyId)
    }
}
