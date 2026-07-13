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
            body: ""
        )

        #expect(store.notifications.map(\.id) == [replacementId, restored.id, live.id])
        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: surfaceId) == replacementId)
    }

    private func notification(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        createdAt: Date
    ) -> TerminalNotification {
        TerminalNotification(
            id: id, tabId: tabId, surfaceId: surfaceId,
            title: title, subtitle: "", body: "",
            createdAt: createdAt, isRead: false
        )
    }
}
