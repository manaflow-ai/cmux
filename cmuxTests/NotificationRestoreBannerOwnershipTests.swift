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

    @Test func coldRestoreDoesNotInferBannerOwnershipFromChronology() {
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

        #expect(ownership.owner(tabId: tabId, surfaceId: surfaceId) == nil)
    }

    @Test func legacyColdRestoreInfersLatestUnreadBannerOwnerPerSurface() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tabId = UUID()
        let firstSurfaceId = UUID()
        let secondSurfaceId = UUID()
        let older = notification(
            id: UUID(), tabId: tabId, surfaceId: firstSurfaceId,
            title: "Older unread", createdAt: Date(timeIntervalSince1970: 10)
        )
        let latestUnread = notification(
            id: UUID(), tabId: tabId, surfaceId: firstSurfaceId,
            title: "Latest unread", createdAt: Date(timeIntervalSince1970: 20)
        )
        let newerRead = notification(
            id: UUID(), tabId: tabId, surfaceId: firstSurfaceId,
            title: "Newer read", createdAt: Date(timeIntervalSince1970: 30),
            isRead: true
        )
        let secondSurface = notification(
            id: UUID(), tabId: tabId, surfaceId: secondSurfaceId,
            title: "Second surface", createdAt: Date(timeIntervalSince1970: 15)
        )
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        store.replaceNotificationsForTesting([])
        store.restoreSessionNotifications(
            [older, latestUnread, newerRead, secondSurface],
            forTabId: tabId,
            inferLegacyExternalBannerOwners: true
        )

        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: firstSurfaceId) == latestUnread.id)
        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: secondSurfaceId) == secondSurface.id)

        store.replaceNotificationsForTesting([])
        store.restoreSessionNotifications([latestUnread], forTabId: tabId)

        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: firstSurfaceId) == nil)
    }

    @Test func olderAcceptedNotificationPreservesVisibleBannerOwner() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let tabId = UUID()
        let surfaceId = UUID()
        let visibleOwner = notification(
            id: UUID(), tabId: tabId, surfaceId: surfaceId,
            title: "Visible owner", createdAt: Date(timeIntervalSince1970: 20)
        )
        let olderId = UUID()
        var deliveredIds: [UUID] = []
        defer {
            store.replaceNotificationsForTesting(previousNotifications)
            store.resetNotificationDeliveryHandlerForTesting()
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        store.replaceNotificationsForTesting([visibleOwner])
        AppFocusState.overrideIsFocused = false
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredIds.append(notification.id)
        }

        store.addNotification(
            id: olderId,
            acceptedAt: Date(timeIntervalSince1970: 10),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Older incoming",
            subtitle: "",
            body: "",
            retargetsToLiveSurfaceOwner: false
        )

        #expect(store.notifications.map(\.id) == [visibleOwner.id, olderId])
        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: surfaceId) == visibleOwner.id)
        #expect(deliveredIds.isEmpty)
    }

    @Test func clearingBannerOwnerByIDPreservesOtherOwners() throws {
        let tabId = UUID()
        let owners = (0..<512).map { index in
            notification(
                id: UUID(),
                tabId: tabId,
                surfaceId: UUID(),
                title: "Owner \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        var ownership = ExternalNotificationBannerOwnership()

        for owner in owners {
            ownership.setOwner(owner)
        }

        ownership.clear(id: UUID())
        #expect(Set(ownership.ownerIDs(tabId: tabId)) == Set(owners.map(\.id)))

        let removed = try #require(owners.dropFirst(257).first)
        ownership.clear(id: removed.id)

        #expect(ownership.owner(tabId: tabId, surfaceId: removed.surfaceId) == nil)
        #expect(Set(ownership.ownerIDs(tabId: tabId)) == Set(owners.map(\.id)).subtracting([removed.id]))
    }

    @Test func rebindFindsAndClearsBannerOwnerThroughPanelAlias() {
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let sourceSurfaceId = UUID()
        let destinationSurfaceId = UUID()
        let panelId = UUID()
        let sourceOwner = TerminalNotification(
            id: UUID(),
            tabId: sourceTabId,
            surfaceId: sourceSurfaceId,
            panelId: panelId,
            title: "Newer source owner",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 30),
            isRead: false
        )
        let destinationOwner = TerminalNotification(
            id: UUID(),
            tabId: destinationTabId,
            surfaceId: destinationSurfaceId,
            panelId: panelId,
            title: "Older destination owner",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 20),
            isRead: false
        )
        var ownership = ExternalNotificationBannerOwnership()
        ownership.setOwner(sourceOwner)
        ownership.setOwner(destinationOwner)

        let displaced = ownership.rebind(
            surfaceId: panelId,
            fromTabId: sourceTabId,
            toTabId: destinationTabId
        )

        #expect(displaced?.id == destinationOwner.id)
        #expect(ownership.ownerIDs(tabId: sourceTabId).isEmpty)
        #expect(ownership.ownerIDs(tabId: destinationTabId) == [sourceOwner.id])
        #expect(ownership.owner(tabId: destinationTabId, surfaceId: sourceSurfaceId)?.id == sourceOwner.id)
        #expect(ownership.owner(tabId: destinationTabId, surfaceId: destinationSurfaceId) == nil)
    }

    @Test func unaffectedSessionRestoreDoesNotResortGlobalFeed() {
        let targetTabId = UUID()
        let otherTabId = UUID()
        let older = notification(
            id: UUID(),
            tabId: otherTabId,
            surfaceId: nil,
            title: "Older first by caller order",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let newer = notification(
            id: UUID(),
            tabId: otherTabId,
            surfaceId: nil,
            title: "Newer second by caller order",
            createdAt: Date(timeIntervalSince1970: 2)
        )

        let merged = TerminalNotificationStore.mergeRestoredSessionNotifications(
            existing: [older, newer],
            restored: [],
            tabId: targetTabId,
            replacingTabId: nil,
            panelIdMap: [:]
        )

        #expect(merged.map(\.id) == [older.id, newer.id])
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
        let sourceSupersededId = UUID()
        let destinationSupersededId = UUID()
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
            _ = store.flushSupersededPhoneDismissIDsForTesting(
                tabId: sourceTabId,
                surfaceId: sourceSurfaceId
            )
            _ = store.flushSupersededPhoneDismissIDsForTesting(
                tabId: destinationTabId,
                surfaceId: destinationSurfaceId
            )
            store.reloadDismissedTombstonesForTesting()
            store.replaceNotificationsForTesting(previousNotifications)
        }

        UserDefaults.standard.removeObject(forKey: tombstoneKey)
        store.reloadDismissedTombstonesForTesting()
        store.replaceNotificationsForTesting([destinationOwner, sourceOwner])
        store.stashSupersededPhoneDismissIDsForTesting(
            [sourceSupersededId.uuidString],
            tabId: sourceTabId,
            surfaceId: sourceSurfaceId
        )
        store.stashSupersededPhoneDismissIDsForTesting(
            [destinationSupersededId.uuidString],
            tabId: destinationTabId,
            surfaceId: destinationSurfaceId
        )

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
        #expect(tombstones.contains(sourceSupersededId.uuidString))
        #expect(!tombstones.contains(destinationOwner.id.uuidString))
        #expect(!tombstones.contains(destinationSupersededId.uuidString))
        #expect(
            store.flushSupersededPhoneDismissIDsForTesting(
                tabId: destinationTabId,
                surfaceId: destinationSurfaceId
            ) == [destinationSupersededId.uuidString]
        )
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
        let destinationSupersededId = UUID()
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
        store.stashSupersededPhoneDismissIDsForTesting(
            [destinationSupersededId.uuidString],
            tabId: destinationTabId,
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
        #expect(!tombstones.contains(destinationSupersededId.uuidString))
        #expect(
            store.flushSupersededPhoneDismissIDsForTesting(
                tabId: destinationTabId,
                surfaceId: surfaceId
            ) == [destinationSupersededId.uuidString]
        )
    }

    @Test func transferCollisionDrainsDestinationBacklogWhenDestinationOwnerLoses() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = UserDefaults.standard.object(forKey: tombstoneKey)
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let sourceSurfaceId = UUID()
        let destinationSurfaceId = UUID()
        let sourceSupersededId = UUID()
        let destinationSupersededId = UUID()
        let sourceOwner = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: sourceSurfaceId,
            title: "Newer source owner", createdAt: Date(timeIntervalSince1970: 30)
        )
        let destinationOwner = notification(
            id: UUID(), tabId: destinationTabId, surfaceId: destinationSurfaceId,
            title: "Older destination owner", createdAt: Date(timeIntervalSince1970: 20)
        )
        defer {
            if let previousTombstones {
                UserDefaults.standard.set(previousTombstones, forKey: tombstoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tombstoneKey)
            }
            _ = store.flushSupersededPhoneDismissIDsForTesting(
                tabId: sourceTabId,
                surfaceId: sourceSurfaceId
            )
            _ = store.flushSupersededPhoneDismissIDsForTesting(
                tabId: destinationTabId,
                surfaceId: destinationSurfaceId
            )
            store.reloadDismissedTombstonesForTesting()
            store.replaceNotificationsForTesting(previousNotifications)
        }

        UserDefaults.standard.removeObject(forKey: tombstoneKey)
        store.reloadDismissedTombstonesForTesting()
        store.replaceNotificationsForTesting([sourceOwner, destinationOwner])
        store.stashSupersededPhoneDismissIDsForTesting(
            [sourceSupersededId.uuidString],
            tabId: sourceTabId,
            surfaceId: sourceSurfaceId
        )
        store.stashSupersededPhoneDismissIDsForTesting(
            [destinationSupersededId.uuidString],
            tabId: destinationTabId,
            surfaceId: destinationSurfaceId
        )

        store.transferSessionNotificationState(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            panelIdMap: [sourceSurfaceId: destinationSurfaceId]
        )

        #expect(
            store.externalBannerOwnerIDForTesting(
                tabId: destinationTabId,
                surfaceId: destinationSurfaceId
            ) == sourceOwner.id
        )
        let tombstones = UserDefaults.standard.stringArray(forKey: tombstoneKey) ?? []
        #expect(tombstones.contains(destinationOwner.id.uuidString))
        #expect(tombstones.contains(destinationSupersededId.uuidString))
        #expect(!tombstones.contains(sourceOwner.id.uuidString))
        #expect(!tombstones.contains(sourceSupersededId.uuidString))
        #expect(
            store.flushSupersededPhoneDismissIDsForTesting(
                tabId: destinationTabId,
                surfaceId: destinationSurfaceId
            ) == [sourceSupersededId.uuidString]
        )
    }

    @Test func rebindCollisionDrainsDestinationBacklogWhenDestinationOwnerLoses() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = UserDefaults.standard.object(forKey: tombstoneKey)
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let surfaceId = UUID()
        let sourceSupersededId = UUID()
        let destinationSupersededId = UUID()
        let sourceOwner = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: surfaceId,
            title: "Newer source owner", createdAt: Date(timeIntervalSince1970: 30)
        )
        let destinationOwner = notification(
            id: UUID(), tabId: destinationTabId, surfaceId: surfaceId,
            title: "Older destination owner", createdAt: Date(timeIntervalSince1970: 20)
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
        store.replaceNotificationsForTesting([sourceOwner, destinationOwner])
        store.stashSupersededPhoneDismissIDsForTesting(
            [sourceSupersededId.uuidString],
            tabId: sourceTabId,
            surfaceId: surfaceId
        )
        store.stashSupersededPhoneDismissIDsForTesting(
            [destinationSupersededId.uuidString],
            tabId: destinationTabId,
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
            ) == sourceOwner.id
        )
        let tombstones = UserDefaults.standard.stringArray(forKey: tombstoneKey) ?? []
        #expect(tombstones.contains(destinationOwner.id.uuidString))
        #expect(tombstones.contains(destinationSupersededId.uuidString))
        #expect(!tombstones.contains(sourceOwner.id.uuidString))
        #expect(!tombstones.contains(sourceSupersededId.uuidString))
        #expect(
            store.flushSupersededPhoneDismissIDsForTesting(
                tabId: destinationTabId,
                surfaceId: surfaceId
            ) == [sourceSupersededId.uuidString]
        )
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

    @Test func transferCollisionKeepsNewerMovedBannerOwner() throws {
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let sourceSurfaceId = UUID()
        let destinationSurfaceId = UUID()
        let sourceOwner = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: sourceSurfaceId,
            title: "Newer source owner", createdAt: Date(timeIntervalSince1970: 30)
        )
        let destinationOwner = notification(
            id: UUID(), tabId: destinationTabId, surfaceId: destinationSurfaceId,
            title: "Older destination owner", createdAt: Date(timeIntervalSince1970: 20)
        )
        var ownership = ExternalNotificationBannerOwnership()
        ownership.setOwner(sourceOwner)
        ownership.setOwner(destinationOwner)

        let displaced = ownership.transfer(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            panelIdMap: [sourceSurfaceId: destinationSurfaceId]
        )

        #expect(ownership.owner(tabId: destinationTabId, surfaceId: destinationSurfaceId)?.id == sourceOwner.id)
        #expect(displaced.map(\.id) == [destinationOwner.id])
    }

    @Test func rebindKeepsSourceConfinedBannerOwnerAtSource() throws {
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

        let preserved = try #require(ownership.owner(tabId: sourceTabId, surfaceId: surfaceId))
        #expect(!preserved.retargetsToLiveSurfaceOwner)
        #expect(ownership.owner(tabId: destinationTabId, surfaceId: surfaceId) == nil)
    }

    @Test func rebindCollisionKeepsNewerMovedBannerOwner() throws {
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let surfaceId = UUID()
        let sourceOwner = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: surfaceId,
            title: "Newer source owner", createdAt: Date(timeIntervalSince1970: 30)
        )
        let destinationOwner = notification(
            id: UUID(), tabId: destinationTabId, surfaceId: surfaceId,
            title: "Older destination owner", createdAt: Date(timeIntervalSince1970: 20)
        )
        var ownership = ExternalNotificationBannerOwnership()
        ownership.setOwner(sourceOwner)
        ownership.setOwner(destinationOwner)

        let displaced = ownership.rebind(
            surfaceId: surfaceId,
            fromTabId: sourceTabId,
            toTabId: destinationTabId
        )

        #expect(ownership.owner(tabId: destinationTabId, surfaceId: surfaceId)?.id == sourceOwner.id)
        #expect(displaced?.id == destinationOwner.id)
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
        let supersededId = UUID().uuidString
        defer {
            _ = store.flushSupersededPhoneDismissIDsForTesting(tabId: sourceTabId, surfaceId: surfaceId)
            _ = store.flushSupersededPhoneDismissIDsForTesting(tabId: destinationTabId, surfaceId: surfaceId)
            store.replaceNotificationsForTesting(previousNotifications)
        }

        store.replaceNotificationsForTesting([sourceConfinedOwner, retargetingRow])
        store.stashSupersededPhoneDismissIDsForTesting(
            [supersededId], tabId: sourceTabId, surfaceId: surfaceId
        )
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
        #expect(
            store.flushSupersededPhoneDismissIDsForTesting(tabId: sourceTabId, surfaceId: surfaceId)
                == [supersededId]
        )
        #expect(
            store.flushSupersededPhoneDismissIDsForTesting(tabId: destinationTabId, surfaceId: surfaceId)
                == []
        )
    }

    @Test func readSourceConfinedHistoryDoesNotPinFocusedIndicatorAtSource() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let surfaceId = UUID()
        let readSourceConfinedHistory = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: surfaceId,
            title: "Read source history", createdAt: Date(timeIntervalSince1970: 10),
            retargetsToLiveSurfaceOwner: false,
            isRead: true
        )
        let movingUnread = notification(
            id: UUID(), tabId: sourceTabId, surfaceId: surfaceId,
            title: "Moving unread", createdAt: Date(timeIntervalSince1970: 20)
        )
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        store.replaceNotificationsForTesting([movingUnread, readSourceConfinedHistory])
        store.setFocusedReadIndicator(forTabId: sourceTabId, surfaceId: surfaceId)
        store.rebindSurfaceNotifications(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            surfaceId: surfaceId
        )

        #expect(store.focusedReadIndicatorSurfaceId(forTabId: sourceTabId) == nil)
        #expect(store.focusedReadIndicatorSurfaceId(forTabId: destinationTabId) == surfaceId)
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

    @Test func explicitlyRestoredReadBannerOwnerOwnsRowActions() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tabId = UUID()
        let surfaceId = UUID()
        let restoredOwner = notification(
            id: UUID(), tabId: tabId, surfaceId: surfaceId,
            title: "Read restored owner",
            createdAt: Date(timeIntervalSince1970: 20),
            isRead: true
        )
        defer {
            _ = store.flushSupersededPhoneDismissIDsForTesting(tabId: tabId, surfaceId: surfaceId)
            store.replaceNotificationsForTesting(previousNotifications)
        }

        store.replaceNotificationsForTesting([])
        store.applySessionNotificationMerge(
            [restoredOwner],
            restoredExternalBannerOwnerIDs: [restoredOwner.id]
        )

        #expect(store.externalBannerOwnerIDForTesting(tabId: tabId, surfaceId: surfaceId) == restoredOwner.id)
        store.stashSupersededPhoneDismissIDsForTesting(
            ["drain-with-restored-read-owner"], tabId: tabId, surfaceId: surfaceId
        )
        store.remove(id: restoredOwner.id)
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

    @Test func feedCapEvictionDismissesEvictedBannerOwner() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = UserDefaults.standard.object(forKey: tombstoneKey)
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let evictedTabId = UUID()
        let evictedSurfaceId = UUID()
        let evictedId = UUID()
        let evicted = notification(
            id: evictedId,
            tabId: evictedTabId,
            surfaceId: evictedSurfaceId,
            title: "Evicted owner",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let retained = (1..<TerminalNotificationStore.maximumNotificationFeedCount).map { index in
            notification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: UUID(),
                title: "Retained \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        defer {
            if let previousTombstones {
                UserDefaults.standard.set(previousTombstones, forKey: tombstoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tombstoneKey)
            }
            store.reloadDismissedTombstonesForTesting()
            store.replaceNotificationsForTesting(previousNotifications)
            store.resetNotificationDeliveryHandlerForTesting()
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        UserDefaults.standard.removeObject(forKey: tombstoneKey)
        store.reloadDismissedTombstonesForTesting()
        AppFocusState.overrideIsFocused = false
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.replaceNotificationsForTesting(([evicted] + retained).sorted(by: TerminalNotificationStore.notificationSortPrecedes))
        #expect(store.externalBannerOwnerIDForTesting(tabId: evictedTabId, surfaceId: evictedSurfaceId) == evictedId)

        store.addNotification(
            id: UUID(),
            acceptedAt: Date(timeIntervalSince1970: TimeInterval(TerminalNotificationStore.maximumNotificationFeedCount + 1)),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Replacement at cap",
            subtitle: "",
            body: "",
            retargetsToLiveSurfaceOwner: false
        )

        #expect(!store.notifications.contains(where: { $0.id == evictedId }))
        #expect(store.externalBannerOwnerIDForTesting(tabId: evictedTabId, surfaceId: evictedSurfaceId) == nil)
        let tombstones = UserDefaults.standard.stringArray(forKey: tombstoneKey) ?? []
        #expect(tombstones.contains(evictedId.uuidString))
    }

    @Test func feedCapMiddleInsertionDismissesEvictedBannerOwner() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = UserDefaults.standard.object(forKey: tombstoneKey)
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let evictedTabId = UUID()
        let evictedSurfaceId = UUID()
        let evictedId = UUID()
        let evicted = notification(
            id: evictedId,
            tabId: evictedTabId,
            surfaceId: evictedSurfaceId,
            title: "Evicted owner",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let retained = (1..<TerminalNotificationStore.maximumNotificationFeedCount).map { index in
            notification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: UUID(),
                title: "Retained \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        defer {
            if let previousTombstones {
                UserDefaults.standard.set(previousTombstones, forKey: tombstoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tombstoneKey)
            }
            store.reloadDismissedTombstonesForTesting()
            store.replaceNotificationsForTesting(previousNotifications)
            store.resetNotificationDeliveryHandlerForTesting()
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        UserDefaults.standard.removeObject(forKey: tombstoneKey)
        store.reloadDismissedTombstonesForTesting()
        AppFocusState.overrideIsFocused = false
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.replaceNotificationsForTesting(([evicted] + retained).sorted(by: TerminalNotificationStore.notificationSortPrecedes))
        #expect(store.externalBannerOwnerIDForTesting(tabId: evictedTabId, surfaceId: evictedSurfaceId) == evictedId)

        store.addNotification(
            id: UUID(),
            acceptedAt: Date(timeIntervalSince1970: 10_000.5),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Middle retained",
            subtitle: "",
            body: "",
            retargetsToLiveSurfaceOwner: false
        )

        #expect(!store.notifications.contains(where: { $0.id == evictedId }))
        #expect(store.externalBannerOwnerIDForTesting(tabId: evictedTabId, surfaceId: evictedSurfaceId) == nil)
        let tombstones = UserDefaults.standard.stringArray(forKey: tombstoneKey) ?? []
        #expect(tombstones.contains(evictedId.uuidString))
    }

    @Test func feedCapOlderInsertionDoesNotDeliverAbsentRow() {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let oldId = UUID()
        let oldTabId = UUID()
        var deliveredIds: [UUID] = []
        let retained = (1...TerminalNotificationStore.maximumNotificationFeedCount).map { index in
            notification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: UUID(),
                title: "Retained \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        defer {
            store.replaceNotificationsForTesting(previousNotifications)
            store.resetNotificationDeliveryHandlerForTesting()
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        AppFocusState.overrideIsFocused = false
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredIds.append(notification.id)
        }
        store.replaceNotificationsForTesting(retained.sorted(by: TerminalNotificationStore.notificationSortPrecedes))
        store.markUnread(forTabId: oldTabId)

        store.addNotification(
            id: oldId,
            acceptedAt: Date(timeIntervalSince1970: 0),
            tabId: oldTabId,
            surfaceId: UUID(),
            title: "Too old",
            subtitle: "",
            body: "",
            retargetsToLiveSurfaceOwner: false
        )

        #expect(!store.notifications.contains(where: { $0.id == oldId }))
        #expect(deliveredIds.isEmpty)
        #expect(store.hasManualUnread(forTabId: oldTabId))
    }

    private func notification(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        createdAt: Date,
        retargetsToLiveSurfaceOwner: Bool = true,
        isRead: Bool = false
    ) -> TerminalNotification {
        TerminalNotification(
            id: id, tabId: tabId, surfaceId: surfaceId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            title: title, subtitle: "", body: "",
            createdAt: createdAt, isRead: isRead
        )
    }
}
