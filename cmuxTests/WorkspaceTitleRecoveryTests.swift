import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceTitleRecoveryTests {
    private func makeCustomizationStore() throws -> (
        store: WorkspaceCustomizationStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "WorkspaceCustomizationStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (
            WorkspaceCustomizationStore(
                defaults: defaults,
                storageKey: "test.customizations",
                legacyStorageKey: "test.legacy-customizations"
            ),
            defaults,
            suiteName
        )
    }

    @Test(arguments: [Workspace.CustomTitleSource.auto, .remote], [false, true])
    func latestTitleWriteSurvivesRecovery(
        source: Workspace.CustomTitleSource,
        restoreClosed: Bool
    ) throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "User Title"))
        if source == .auto {
            manager.clearCustomTitle(tabId: workspace.id)
        }
        manager.setTabColor(tabId: workspace.id, color: "#123456")
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Latest Title", source: source))
        // A later color write must preserve the title's recovery provenance.
        manager.setTabColor(tabId: workspace.id, color: "#ABCDEF")
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let restored = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)

        if restoreClosed {
            #expect(restored.restoreClosedWorkspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspace.id,
                windowId: nil,
                workspaceIndex: 0,
                snapshot: snapshot
            )))
        } else {
            restored.restoreSessionSnapshot(SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [snapshot]
            ))
        }

        let recovered = try #require(restored.selectedWorkspace)
        #expect(recovered.customTitle == "Latest Title")
        #expect(recovered.customTitleSource == source)
        #expect(recovered.customColor == "#ABCDEF")
    }

    @Test(arguments: [Workspace.CustomTitleSource.auto, .remote])
    func latestTitleRecoversOverStaleUserSnapshot(source: Workspace.CustomTitleSource) throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Old User Title"))
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        if source == .auto {
            manager.clearCustomTitle(tabId: workspace.id)
        }
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Latest Title", source: source))

        let restored = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        restored.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [snapshot]
        ))
        #expect(restored.selectedWorkspace?.customTitle == "Latest Title")
        #expect(restored.selectedWorkspace?.customTitleSource == source)
    }

    @Test(arguments: [Workspace.CustomTitleSource.auto, .remote])
    func newerUserRenameRecoversOverNonUserSnapshot(source: Workspace.CustomTitleSource) throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Snapshot Title", source: source))
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "New User Title"))
        // Rejected automatic writes must not replace the recovery record.
        #expect(!manager.setCustomTitle(tabId: workspace.id, title: "Rejected", source: .auto))

        let restored = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        restored.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [snapshot]
        ))
        #expect(restored.selectedWorkspace?.customTitle == "New User Title")
        #expect(restored.selectedWorkspace?.customTitleSource == .user)
    }

    @Test(arguments: [Workspace.CustomTitleSource.auto, .remote], [false, true])
    func legacyTitleJournalDoesNotOverrideNonUserSnapshot(
        source: Workspace.CustomTitleSource,
        cleared: Bool
    ) throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        let workspace = try #require(manager.selectedWorkspace)
        #expect(workspace.setCustomTitle("Snapshot Title", source: source))
        let customization = WorkspaceCustomization(
            customTitle: cleared ? .cleared : .value("Old User Title"),
            customColor: .value("#ABCDEF")
        )
        // Reproduce the on-disk journal written before title provenance existed.
        let data = try JSONEncoder().encode(customization)
        var fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields.removeValue(forKey: "customTitleSource")
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "nextRevision": 1,
            "entries": [workspace.stableId.uuidString: ["revision": 1, "customization": fields]]
        ]), forKey: "test.customizations")

        let restored = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        restored.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [workspace.sessionSnapshot(includeScrollback: false)]
        ))
        #expect(restored.selectedWorkspace?.customTitle == "Snapshot Title")
        #expect(restored.selectedWorkspace?.customTitleSource == source)
        #expect(restored.selectedWorkspace?.customColor == "#ABCDEF")
    }

    @Test
    func closingWorkspaceDropsCustomizationJournal() throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: fixture.store)
        let workspace = try #require(manager.selectedWorkspace)
        _ = manager.addWorkspace(select: false)
        #expect(manager.setCustomTitle(tabId: workspace.id, title: "Closed Title"))
        manager.setTabColor(tabId: workspace.id, color: "#ABCDEF")
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        manager.closeWorkspace(workspace, recordHistory: false)
        #expect(fixture.store.customization(for: workspace.stableId) == nil)
        #expect(manager.restoreClosedWorkspace(ClosedWorkspaceHistoryEntry(
            workspaceId: workspace.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: snapshot
        )))
        #expect(manager.selectedWorkspace?.customTitle == "Closed Title")
        #expect(manager.selectedWorkspace?.customColor == "#ABCDEF")
    }
}
