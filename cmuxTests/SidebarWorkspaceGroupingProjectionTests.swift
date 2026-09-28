import Foundation
import Testing
import CmuxNotifications
import CmuxSettings
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar Group By projection", .serialized)
struct SidebarWorkspaceGroupingProjectionTests {
    private func makeTabManager(workspaceCount: Int) -> TabManager {
        let suiteName = "cmux.sidebar-group-by-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
        while manager.tabs.count < workspaceCount {
            manager.addWorkspace(autoWelcomeIfNeeded: false)
        }
        return manager
    }

    @Test func manualProjectionMatchesTheExistingPipeline() throws {
        let manager = makeTabManager(workspaceCount: 4)
        let children = Array(manager.tabs.prefix(2).map(\.id))
        _ = try #require(manager.createWorkspaceGroup(name: "Grouped", childWorkspaceIds: children))
        _ = try #require(manager.createWorkspaceGroup(name: ""))
        let tabs = manager.tabs
        let groups = manager.workspaceGroups
        let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let membership = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(
            tabs: tabs,
            groupsById: groupsById
        )

        let projection = SidebarWorkspaceGroupingProjection(
            tabs: tabs,
            manualGroups: groups,
            mode: .manual,
            collapsedSectionKeys: ["status:terminals"],
            automaticInputs: []
        )

        #expect(projection.groups == groups)
        #expect(projection.groupIdByWorkspaceId == membership)
        #expect(projection.manualGroupIdByWorkspaceId == membership)
        #expect(projection.memberWorkspaceIdsByGroupId == SidebarWorkspaceRenderItem.memberWorkspaceIdsByGroupId(
            tabs: tabs,
            groupsById: groupsById,
            effectiveMembership: membership
        ))
        #expect(projection.renderItems.map(\.id) == SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: groupsById,
            orderedGroups: groups,
            effectiveMembership: membership
        ).map(\.id))
        #expect(projection.automaticSectionKeyByGroupId.isEmpty)
    }

    @Test func automaticProjectionShowsManualAnchorAsRowAndHonorsCollapse() throws {
        let manager = makeTabManager(workspaceCount: 3)
        let children = Array(manager.tabs.prefix(1).map(\.id))
        let groupId = try #require(manager.createWorkspaceGroup(name: "Grouped", childWorkspaceIds: children))
        let anchorId = try #require(manager.workspaceGroups.first { $0.id == groupId }?.liveAnchorWorkspaceId)
        let tabOrderBefore = manager.tabs.map(\.id)
        let groupsBefore = manager.workspaceGroups
        let inputs = manager.tabs.map { workspace in
            SidebarAutoGroupingInput(
                workspaceId: workspace.id,
                host: .local,
                status: workspace.id == anchorId ? .running : .terminals
            )
        }

        let projection = SidebarWorkspaceGroupingProjection(
            tabs: manager.tabs,
            manualGroups: manager.workspaceGroups,
            mode: .status,
            collapsedSectionKeys: ["status:terminals"],
            automaticInputs: inputs
        )

        let runningId = SidebarAutoGroupingSection.groupId(forKey: "status:running")
        let terminalsId = SidebarAutoGroupingSection.groupId(forKey: "status:terminals")
        // The manual anchor is an ordinary row; the collapsed section hides its rows.
        #expect(projection.renderItems.map(\.id) == [
            .group(runningId),
            .workspace(anchorId),
            .group(terminalsId),
        ])
        #expect(projection.groups.map(\.isCollapsed) == [false, true])
        #expect(projection.groups.allSatisfy { $0.isEmpty && !$0.isPinned })
        #expect(projection.automaticSectionKeyByGroupId[terminalsId] == "status:terminals")
        #expect((projection.manualGroupIdByWorkspaceId[anchorId] ?? nil) == groupId)
        #expect(projection.manualAnchorWorkspaceIds.contains(anchorId))
        #expect(SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: projection.renderItems) == [anchorId])
        // Projection never edits the window's real order or groups.
        #expect(manager.tabs.map(\.id) == tabOrderBefore)
        #expect(manager.workspaceGroups == groupsBefore)
    }

    @Test func observerBumpsRevisionOnlyWhenASectionChanges() throws {
        let manager = makeTabManager(workspaceCount: 2)
        manager.sidebarGroupBy.mode = .status
        let observer = SidebarAutoGroupingObserver()
        observer.attach(tabManager: manager, unreadModel: SidebarUnreadModel())
        defer { observer.detach() }
        let baseline = observer.revision
        let workspace = try #require(manager.tabs.first)

        observer.scheduleRecompute(workspaceId: workspace.id)
        observer.flushPendingRecompute()
        #expect(observer.revision == baseline)

        workspace.agentLifecycleStatesByPanelId = [UUID(): ["claude": .running]]
        observer.scheduleRecompute(workspaceId: workspace.id)
        observer.flushPendingRecompute()
        #expect(observer.revision == baseline &+ 1)
        #expect(observer.inputs(for: manager.tabs, mode: .status).first?.status == .running)

        manager.sidebarGroupBy.mode = .manual
        observer.detach()
        observer.scheduleRecompute(workspaceId: workspace.id)
        observer.flushPendingRecompute()
        #expect(observer.revision == baseline &+ 1)
    }
}
