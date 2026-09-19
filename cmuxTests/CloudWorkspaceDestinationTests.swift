import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudWorkspaceDestinationTests {
    @Test func receiptReplacesSelectedPlaceholder() throws {
        let suite = "cloud-destination-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeManager(defaults: defaults)
        let placeholder = manager.addWorkspace(autoWelcomeIfNeeded: false)
        let created = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        manager.selectedTabId = placeholder.id
        let destination = CloudWorkspaceGroupDestination(
            tabManager: manager, groupId: nil, placement: .end,
            referenceWorkspaceId: nil, initialWorkspaceId: placeholder.id
        )

        destination.apply(workspaceID: created.id)

        #expect(!manager.tabs.contains { $0.id == placeholder.id })
        #expect(manager.selectedTabId == created.id)
    }

    @Test func receiptGroupsOnlyItsOwnWorkspace() throws {
        let suite = "cloud-destination-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeManager(defaults: defaults)
        let groupID = try #require(manager.createWorkspaceGroup(name: "Cloud"))
        let anchor = try #require(manager.workspaceGroups.first { $0.id == groupID }?.liveAnchorWorkspaceId)
        let unrelated = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let created = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let destination = CloudWorkspaceGroupDestination(
            tabManager: manager, groupId: groupID, placement: .end,
            referenceWorkspaceId: anchor, initialWorkspaceId: nil
        )

        destination.apply(workspaceID: created.id)

        #expect(created.groupId == groupID)
        #expect(unrelated.groupId == nil)
    }

    @Test func unknownReceiptDoesNotClosePlaceholder() throws {
        let suite = "cloud-destination-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeManager(defaults: defaults)
        let placeholder = manager.addWorkspace(autoWelcomeIfNeeded: false)
        _ = manager.addWorkspace(autoWelcomeIfNeeded: false)
        let destination = CloudWorkspaceGroupDestination(
            tabManager: manager, groupId: nil, placement: .end,
            referenceWorkspaceId: nil, initialWorkspaceId: placeholder.id
        )

        destination.apply(workspaceID: UUID())

        #expect(manager.tabs.contains { $0.id == placeholder.id })
    }

    @Test func machineReservationCommitsPlacementBeforeProvisioningAndPreservesLaterNavigation() async throws {
        let suite = "cloud-destination-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeManager(defaults: defaults)
        let groupID = try #require(manager.createWorkspaceGroup(name: "Cloud"))
        let anchor = try #require(manager.workspaceGroups.first { $0.id == groupID }?.liveAnchorWorkspaceId)
        let created = manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
        let other = manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
        let presenter = DelayedNewMachineSheetPresenter(workspaceID: created.id)
        let controller = CloudWorkspaceOperationController(isAvailable: { true }, notificationCenter: NotificationCenter())
        let delegate = AppDelegate()
        delegate.cloudWorkspaceOperationController = controller
        delegate.newMachineSheetPresenter = presenter
        let destination = CloudWorkspaceGroupDestination(
            tabManager: manager, groupId: groupID, placement: .end,
            referenceWorkspaceId: anchor, initialWorkspaceId: nil
        )

        #expect(delegate.performNewCloudWorkspaceAction(tabManager: manager, destination: destination))
        for await _ in presenter.accepted { break }
        #expect(created.groupId == groupID, "placement belongs to the reservation, before the server response")

        manager.removeWorkspaceFromGroup(workspaceId: created.id)
        manager.selectedTabId = other.id
        let order = manager.tabs.map(\.id)
        presenter.finish()
        await controller.waitForPendingOperations()

        #expect(created.groupId == nil, "completion must not undo a user move")
        #expect(manager.tabs.map(\.id) == order)
        #expect(manager.selectedTabId == other.id)
    }

    private func makeManager(defaults: UserDefaults) -> TabManager {
        TabManager(
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
    }
}
