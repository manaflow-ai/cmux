import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct NotificationRestoreBannerOwnershipTests {
    @Test func duplicateIdentityDegradesToFirstRowInUnreadNavigation() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tabId = UUID()
        let surfaceId = UUID()
        let duplicateId = UUID()
        let first = notification(
            id: duplicateId, tabId: tabId, surfaceId: surfaceId,
            title: "First canonical row", createdAt: Date(timeIntervalSince1970: 20)
        )
        let duplicate = notification(
            id: duplicateId, tabId: tabId, surfaceId: surfaceId,
            title: "Corrupt duplicate", createdAt: Date(timeIntervalSince1970: 10)
        )
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        store.replaceNotificationsForTesting([first, duplicate])
        #expect(store.markLatestNotificationAsOldestUnread(forTabId: tabId, surfaceId: surfaceId) == duplicateId)
        #expect(store.notificationsForUnreadNavigation.map(\.title) == ["First canonical row"])
    }

    @Test func duplicateIdentityDegradesToFirstRowDuringBannerReconcile() {
        let tabId = UUID()
        let surfaceId = UUID()
        let duplicateId = UUID()
        let first = notification(
            id: duplicateId, tabId: tabId, surfaceId: surfaceId,
            title: "First canonical row", createdAt: Date(timeIntervalSince1970: 20)
        )
        let duplicate = notification(
            id: duplicateId, tabId: tabId, surfaceId: surfaceId,
            title: "Corrupt duplicate", createdAt: Date(timeIntervalSince1970: 10)
        )
        var ownership = ExternalNotificationBannerOwnership()

        ownership.reconcile(previous: [], merged: [first, duplicate])

        #expect(ownership.owner(tabId: tabId, surfaceId: surfaceId)?.title == "First canonical row")
    }

    @Test func transferCollisionDismissesDisplacedBannerOwner() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = UserDefaults.standard.object(forKey: tombstoneKey)
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let sourceSurfaceId = UUID()
        let destinationSurfaceId = UUID()
        let sourceOwner = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: sourceSurfaceId,
            title: "Source owner", createdAt: Date(timeIntervalSince1970: 10)
        )
        let destinationOwner = notification(
            id: UUID(), tabId: destinationTabId, surfaceId: destinationSurfaceId,
            title: "Destination owner", createdAt: Date(timeIntervalSince1970: 20)
        )
        defer {
            if let previousTombstones {
                UserDefaults.standard.set(previousTombstones, forKey: tombstoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tombstoneKey)
            }
            store.reloadDismissedTombstonesForTesting()
            store.replaceNotificationsForTesting(previousNotifications)
        }

        UserDefaults.standard.removeObject(forKey: tombstoneKey)
        store.reloadDismissedTombstonesForTesting()
        store.replaceNotificationsForTesting([destinationOwner, sourceOwner])

        store.transferSessionNotificationState(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            panelIdMap: [sourceSurfaceId: destinationSurfaceId]
        )

        #expect(
            store.externalBannerOwnerIDForTesting(
                tabId: destinationTabId,
                surfaceId: destinationSurfaceId
            ) == destinationOwner.id
        )
        let tombstones = UserDefaults.standard.stringArray(forKey: tombstoneKey) ?? []
        #expect(tombstones.contains(sourceOwner.id.uuidString))
        #expect(!tombstones.contains(destinationOwner.id.uuidString))
    }

    @Test func rebindCollisionDismissesDisplacedBannerOwner() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = UserDefaults.standard.object(forKey: tombstoneKey)
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let surfaceId = UUID()
        let sourceSupersededId = UUID()
        let sourceOwner = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: surfaceId,
            title: "Source owner", createdAt: Date(timeIntervalSince1970: 10)
        )
        let destinationOwner = notification(
            id: UUID(), tabId: destinationTabId, surfaceId: surfaceId,
            title: "Destination owner", createdAt: Date(timeIntervalSince1970: 20)
        )
        defer {
            if let previousTombstones {
                UserDefaults.standard.set(previousTombstones, forKey: tombstoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tombstoneKey)
            }
            _ = store.flushSupersededPhoneDismissIDsForTesting(tabId: sourceTabId, surfaceId: surfaceId)
            _ = store.flushSupersededPhoneDismissIDsForTesting(tabId: destinationTabId, surfaceId: surfaceId)
            store.reloadDismissedTombstonesForTesting()
            store.replaceNotificationsForTesting(previousNotifications)
        }

        UserDefaults.standard.removeObject(forKey: tombstoneKey)
        store.reloadDismissedTombstonesForTesting()
        store.replaceNotificationsForTesting([destinationOwner, sourceOwner])
        store.stashSupersededPhoneDismissIDsForTesting(
            [sourceSupersededId.uuidString],
            tabId: sourceTabId,
            surfaceId: surfaceId
        )

        store.rebindSurfaceNotifications(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            surfaceId: surfaceId
        )

        #expect(
            store.externalBannerOwnerIDForTesting(
                tabId: destinationTabId,
                surfaceId: surfaceId
            ) == destinationOwner.id
        )
        let tombstones = UserDefaults.standard.stringArray(forKey: tombstoneKey) ?? []
        #expect(tombstones.contains(sourceOwner.id.uuidString))
        #expect(tombstones.contains(sourceSupersededId.uuidString))
        #expect(!tombstones.contains(destinationOwner.id.uuidString))
    }

    @Test func transferPreservesSourceConfinedBannerOwner() throws {
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let surfaceId = UUID()
        let owner = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: surfaceId,
            title: "Source-confined owner", createdAt: Date(timeIntervalSince1970: 10),
            retargetsToLiveSurfaceOwner: false
        )
        var ownership = ExternalNotificationBannerOwnership()
        ownership.setOwner(owner)

        #expect(ownership.transfer(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            panelIdMap: [:]
        ).isEmpty)

        let moved = try #require(ownership.owner(tabId: destinationTabId, surfaceId: surfaceId))
        #expect(!moved.retargetsToLiveSurfaceOwner)
    }

    @Test func rebindPreservesSourceConfinedBannerOwner() throws {
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let surfaceId = UUID()
        let owner = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: surfaceId,
            title: "Source-confined owner", createdAt: Date(timeIntervalSince1970: 10),
            retargetsToLiveSurfaceOwner: false
        )
        var ownership = ExternalNotificationBannerOwnership()
        ownership.setOwner(owner)

        #expect(ownership.rebind(
            surfaceId: surfaceId,
            fromTabId: sourceTabId,
            toTabId: destinationTabId
        ) == nil)

        let moved = try #require(ownership.owner(tabId: destinationTabId, surfaceId: surfaceId))
        #expect(!moved.retargetsToLiveSurfaceOwner)
    }

    @Test func sourceConfinedBannerOwnerStaysWithSourceWhenOtherRowsRebind() throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let surfaceId = UUID()
        let sourceConfinedOwner = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: surfaceId,
            title: "Source-confined owner", createdAt: Date(timeIntervalSince1970: 20),
            retargetsToLiveSurfaceOwner: false
        )
        let retargetingRow = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: surfaceId,
            title: "Retargeting row", createdAt: Date(timeIntervalSince1970: 10)
        )
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        store.replaceNotificationsForTesting([sourceConfinedOwner, retargetingRow])
        store.rebindSurfaceNotifications(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            surfaceId: surfaceId
        )

        #expect(
            store.externalBannerOwnerIDForTesting(tabId: sourceTabId, surfaceId: surfaceId)
                == sourceConfinedOwner.id
        )
        #expect(store.externalBannerOwnerIDForTesting(tabId: destinationTabId, surfaceId: surfaceId) == nil)
        #expect(store.notifications.first(where: { $0.id == sourceConfinedOwner.id })?.tabId == sourceTabId)
        #expect(store.notifications.first(where: { $0.id == retargetingRow.id })?.tabId == destinationTabId)
    }

    @Test func restoredNewerRowDoesNotOwnLiveBannerRowActions() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tabId = UUID()
        let surfaceId = UUID()
        let live = notification(
            id: UUID(), tabId: tabId, surfaceId: surfaceId,
            title: "Live banner", createdAt: Date(timeIntervalSince1970: 10)
        )
        let restored = notification(
            id: UUID(), tabId: tabId, surfaceId: surfaceId,
            title: "Newer restored row", createdAt: Date(timeIntervalSince1970: 20)
        )
        defer {
            _ = store.flushSupersededPhoneDismissIDsForTesting(tabId: tabId, surfaceId: surfaceId)
            store.replaceNotificationsForTesting(previousNotifications)
        }

        store.replaceNotificationsForTesting([live])
        store.restoreSessionNotifications([restored], forTabId: tabId)
        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: surfaceId) == live.id)
        store.stashSupersededPhoneDismissIDsForTesting(
            ["preserve-for-live-owner"], tabId: tabId, surfaceId: surfaceId
        )

        store.markRead(id: restored.id)
        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: surfaceId) == live.id)
        #expect(
            store.flushSupersededPhoneDismissIDsForTesting(tabId: tabId, surfaceId: surfaceId)
                == ["preserve-for-live-owner"]
        )

        store.stashSupersededPhoneDismissIDsForTesting(
            ["drain-with-live-owner"], tabId: tabId, surfaceId: surfaceId
        )
        store.markRead(id: live.id)
        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: surfaceId) == nil)
        #expect(store.flushSupersededPhoneDismissIDsForTesting(tabId: tabId, surfaceId: surfaceId) == [])
    }

    @Test func nextLiveNotificationSupersedesLiveOwnerInsteadOfNewerRestoredRow() {
        let store = TerminalNotificationStore.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let live = notification(
            id: UUID(), tabId: tabId, surfaceId: surfaceId,
            title: "Live owner", createdAt: Date(timeIntervalSince1970: 10)
        )
        let restored = notification(
            id: UUID(), tabId: tabId, surfaceId: surfaceId,
            title: "Restored row", createdAt: Date(timeIntervalSince1970: 20)
        )
        let replacementId = UUID()
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([live])
        AppFocusState.overrideIsFocused = false
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        store.restoreSessionNotifications([restored], forTabId: tabId)
        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: surfaceId) == live.id)

        store.addNotification(
            id: replacementId,
            acceptedAt: Date(timeIntervalSince1970: 30),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Replacement",
            subtitle: "",
            body: "",
            retargetsToLiveSurfaceOwner: false
        )

        #expect(store.notifications.map(\.id) == [replacementId, restored.id, live.id])
        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: surfaceId) == replacementId)
    }

    private func notification(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        createdAt: Date,
        retargetsToLiveSurfaceOwner: Bool = true
    ) -> TerminalNotification {
        TerminalNotification(
            id: id, tabId: tabId, surfaceId: surfaceId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            title: title, subtitle: "", body: "",
            createdAt: createdAt, isRead: false
        )
    }
}
