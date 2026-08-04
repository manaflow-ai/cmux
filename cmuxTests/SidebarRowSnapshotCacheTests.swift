import CmuxSidebar
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
    @Test func insertionRejectsCurrentWorkSnapshotFromAnotherWorkspace() throws {
        let suiteName = "SidebarRowSnapshotCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let workspaceA = Workspace(title: "Workspace A", initialSurface: .cloudVMLoading)
        let workspaceB = Workspace(title: "Workspace B", initialSurface: .cloudVMLoading)
        let insertedWorkspace = Workspace(title: "New workspace", initialSurface: .cloudVMLoading)
        defer {
            workspaceA.teardownAllPanels()
            workspaceB.teardownAllPanels()
            insertedWorkspace.teardownAllPanels()
        }
        let currentWork = SidebarStatusEntry(key: "current_work", value: "Needs input")
        workspaceA.statusEntries[currentWork.key] = currentWork
        let workspaces = [insertedWorkspace, workspaceA, workspaceB]
        let expectedSnapshots = Dictionary(uniqueKeysWithValues: workspaces.map { workspace in
            (workspace.id, SidebarWorkspaceSnapshotFactory(
                workspace: workspace,
                settings: settings,
                showsAgentActivity: false
            ).makeSnapshot())
        })
        let snapshotA = try #require(expectedSnapshots[workspaceA.id])
        let snapshotB = try #require(expectedSnapshots[workspaceB.id])
        #expect(snapshotA.metadataEntries == [currentWork])

        // Model a recycled row carrying A's snapshot into the newly inserted row.
        // Every row has identical display settings; the owner must distinguish them.
        let cache = SidebarRowSnapshotCache()
        cache.replace(with: [
            insertedWorkspace.id: snapshotA,
            workspaceA.id: snapshotA,
            workspaceB.id: snapshotB,
        ])
        var rebuiltWorkspaceIds: [UUID] = []
        cache.reconcile(
            workspaceIds: Set(workspaces.map(\.id)),
            presentationKey: { expectedSnapshots[$0]!.presentationKey }
        ) { workspaceId in
            rebuiltWorkspaceIds.append(workspaceId)
            return expectedSnapshots[workspaceId]
        }

        let insertedSnapshot = try #require(cache.value(for: insertedWorkspace.id))
        #expect(insertedSnapshot.metadataEntries.isEmpty)
        #expect(insertedSnapshot.title == insertedWorkspace.title)
        #expect(cache.value(for: workspaceA.id)?.metadataEntries == [currentWork])
        #expect(cache.value(for: workspaceB.id)?.metadataEntries.isEmpty == true)
        #expect(rebuiltWorkspaceIds == [insertedWorkspace.id])

    }

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
        let disabledFactory = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
            showsAgentActivity: false
        )
        let disabledSnapshot = disabledFactory.makeSnapshot()
        #expect(disabledSnapshot.customColorHex == nil)
        #expect(disabledSnapshot.hasManualCustomColor == false)

        let factory = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
            showsAgentActivity: false,
            originColorHex: originColor
        )
        let cache = SidebarRowSnapshotCache()
        let defaultSnapshot = factory.makeSnapshot()
        #expect(defaultSnapshot.customColorHex == originColor)
        #expect(defaultSnapshot.hasManualCustomColor == false)

        let manualColor = "#FF945A"
        workspace.customColor = manualColor
        let differentManualSnapshot = factory.makeSnapshot()
        #expect(differentManualSnapshot.customColorHex == manualColor)
        #expect(differentManualSnapshot.hasManualCustomColor == true)

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
