import Testing
import AppKit
import UserNotifications
import CMUXMobileCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cross-device notification dismiss-sync: the mobile `notification.dismiss`
/// and `notification.reconcile` host verbs, dismiss tombstones, the
/// superseded-banner dismiss buffer, and the authoritative phone badge count.
///
/// Serialized because every case mutates process-wide singletons
/// (`TerminalNotificationStore.shared`, `UserDefaults.standard`); each restores
/// the prior state in a `defer`, but they must not interleave.
@MainActor
@Suite(.serialized)
struct NotificationDismissSyncTests {

    // MARK: - notification.dismiss (cross-device dismiss-sync)

    /// A phone-side banner swipe routes `notification.dismiss` over the mobile
    /// host channel and must mark the matching Mac notification *read* (banner
    /// cleared, entry retained), mirroring a Mac-side banner swipe — NOT remove
    /// it like the socket `notification.dismiss` verb.
    @Test func mobileNotificationDismissMarksReadAndKeepsEntry() async throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let tabId = UUID()
        let target = TerminalNotification(
            id: UUID(), tabId: tabId, surfaceId: UUID(),
            title: "Dismiss me", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_000), isRead: false
        )
        let sibling = TerminalNotification(
            id: UUID(), tabId: tabId, surfaceId: UUID(),
            title: "Keep me", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_001), isRead: false
        )
        store.replaceNotificationsForTesting([target, sibling])

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "dismiss",
                method: "notification.dismiss",
                params: ["notification_id": target.id.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response else {
            Issue.record("Expected notification.dismiss to succeed, got \(response)")
            return
        }
        let payload = try #require(rawPayload as? [String: Any])
        #expect(payload["dismissed"] as? Int == 1)
        // markRead, not remove: both entries remain in the store.
        #expect(store.notifications.first(where: { $0.id == target.id })?.isRead == true)
        #expect(store.notifications.first(where: { $0.id == sibling.id })?.isRead == false)
        #expect(store.notifications.count == 2)
    }

    /// A batched Mac clear (e.g. "Mark all read" on the phone) sends an id array;
    /// every listed notification is marked read, unknown ids are ignored.
    @Test func mobileNotificationDismissAcceptsIdArrayAndIgnoresUnknownIds() async throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let tabId = UUID()
        let first = TerminalNotification(
            id: UUID(), tabId: tabId, surfaceId: UUID(),
            title: "One", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_000), isRead: false
        )
        let second = TerminalNotification(
            id: UUID(), tabId: tabId, surfaceId: UUID(),
            title: "Two", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_001), isRead: false
        )
        store.replaceNotificationsForTesting([first, second])

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "dismiss-batch",
                method: "notification.dismiss",
                params: [
                    "notification_ids": [
                        first.id.uuidString,
                        UUID().uuidString, // unknown id, ignored by markRead
                        second.id.uuidString,
                    ]
                ],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response else {
            Issue.record("Expected batched notification.dismiss to succeed, got \(response)")
            return
        }
        let payload = try #require(rawPayload as? [String: Any])
        // dismissed counts real unread→read transitions: the two known unread
        // notifications, not the ignored unknown id.
        #expect(payload["dismissed"] as? Int == 2)
        #expect(store.notifications.first(where: { $0.id == first.id })?.isRead == true)
        #expect(store.notifications.first(where: { $0.id == second.id })?.isRead == true)
    }

    /// A duplicated id in one request (retry artifacts, outbox replay) must
    /// count one dismissal, not double-count or run the markRead path twice.
    @Test func mobileNotificationDismissDedupesDuplicateIds() async throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let target = TerminalNotification(
            id: UUID(), tabId: UUID(), surfaceId: UUID(),
            title: "Dismiss once", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_000), isRead: false
        )
        store.replaceNotificationsForTesting([target])

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "dismiss-dup",
                method: "notification.dismiss",
                params: [
                    "notification_ids": [
                        target.id.uuidString,
                        target.id.uuidString,
                        target.id.uuidString,
                    ]
                ],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response else {
            Issue.record("Expected duplicated notification.dismiss to succeed, got \(response)")
            return
        }
        let payload = try #require(rawPayload as? [String: Any])
        #expect(payload["dismissed"] as? Int == 1)
        #expect(store.notifications.first(where: { $0.id == target.id })?.isRead == true)
    }

    /// A request with no usable id is a client bug, not a silent no-op.
    @Test func mobileNotificationDismissRejectsMissingId() async throws {
        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "dismiss-bad",
                method: "notification.dismiss",
                params: ["notification_id": "not-a-uuid"],
                auth: nil
            )
        )

        guard case let .failure(error) = response else {
            Issue.record("Expected malformed notification.dismiss to fail, got \(response)")
            return
        }
        #expect(error.code == "invalid_params")
    }

    // MARK: - notification.reconcile (foreground sweep) + unread badge count

    /// The phone's reconcile sweep sends its delivered banner ids; the Mac must
    /// report handled = read-in-store OR recently-removed (tombstoned), leave
    /// unread and foreign ids alone, and return the authoritative unread count
    /// the phone SETS its icon badge to.
    @Test func mobileNotificationReconcileClassifiesHandledAndReportsUnreadCount() async throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let tabId = UUID()
        let read = TerminalNotification(
            id: UUID(), tabId: tabId, surfaceId: UUID(),
            title: "Read on Mac", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_000), isRead: true
        )
        let unread = TerminalNotification(
            id: UUID(), tabId: tabId, surfaceId: UUID(),
            title: "Still unread", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_001), isRead: false
        )
        let removed = TerminalNotification(
            id: UUID(), tabId: tabId, surfaceId: UUID(),
            title: "Removed on Mac", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_002), isRead: false
        )
        store.replaceNotificationsForTesting([read, unread, removed])
        // User-driven removal: the entry leaves the store but must stay
        // reconcilable through the dismiss tombstone.
        store.remove(id: removed.id)

        // A banner mirrored from a different paired Mac; this Mac has never seen
        // its id and must NOT claim it as handled.
        let foreignId = UUID()
        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "reconcile",
                method: "notification.reconcile",
                params: [
                    "delivered_ids": [
                        read.id.uuidString,
                        unread.id.uuidString,
                        removed.id.uuidString,
                        foreignId.uuidString,
                    ]
                ],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response else {
            Issue.record("Expected notification.reconcile to succeed, got \(response)")
            return
        }
        let payload = try #require(rawPayload as? [String: Any])
        #expect(payload["handled_ids"] as? [String] == [read.id.uuidString, removed.id.uuidString])
        // The phone badge mirrors unread notification *entries*: only `unread`
        // remains unread in the store.
        #expect(payload["unread_count"] as? Int == 1)
    }

    /// An empty `delivered_ids` is a valid badge-only sync: nothing handled,
    /// count still returned.
    @Test func mobileNotificationReconcileEmptyDeliveredIsBadgeOnlySync() async throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let unread = TerminalNotification(
            id: UUID(), tabId: UUID(), surfaceId: UUID(),
            title: "Unread", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_000), isRead: false
        )
        store.replaceNotificationsForTesting([unread])

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "reconcile-empty",
                method: "notification.reconcile",
                params: ["delivered_ids": [String]()],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response else {
            Issue.record("Expected badge-only notification.reconcile to succeed, got \(response)")
            return
        }
        let payload = try #require(rawPayload as? [String: Any])
        #expect(payload["handled_ids"] as? [String] == [])
        #expect(payload["unread_count"] as? Int == 1)
    }

    /// markRead leaves a dismiss tombstone, but a later markUnread resurrects
    /// the entry: a currently-unread id must never be reported handled, or the
    /// reconcile sweep would clear a banner the user explicitly un-read.
    @Test func reconcileUnreadEntryBeatsStaleDismissTombstone() throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let notification = TerminalNotification(
            id: UUID(), tabId: UUID(), surfaceId: UUID(),
            title: "Resurrected", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_000), isRead: false
        )
        store.replaceNotificationsForTesting([notification])
        store.markRead(id: notification.id) // records a dismiss tombstone
        #expect(
            store.reconcileHandledNotificationIDs(deliveredIDs: [notification.id])
                == [notification.id.uuidString]
        )

        store.markUnread(id: notification.id)

        #expect(store.reconcileHandledNotificationIDs(deliveredIDs: [notification.id]) == [])
    }

    /// Dismiss tombstones are write-through persisted: a notification dismissed
    /// and fully removed before a Mac relaunch must still reconcile as handled
    /// afterwards, or a phone whose silent dismiss push was dropped would keep
    /// the stale banner forever.
    @Test func dismissTombstonesSurviveStoreReload() throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = UserDefaults.standard.stringArray(forKey: tombstoneKey)
        defer {
            store.replaceNotificationsForTesting(previousNotifications)
            if let previousTombstones {
                UserDefaults.standard.set(previousTombstones, forKey: tombstoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tombstoneKey)
            }
            store.reloadDismissedTombstonesForTesting()
        }

        let notification = TerminalNotification(
            id: UUID(), tabId: UUID(), surfaceId: UUID(),
            title: "Cleared before relaunch", subtitle: "", body: "body",
            createdAt: Date(timeIntervalSince1970: 1_778_000_000), isRead: false
        )
        store.replaceNotificationsForTesting([notification])
        store.markRead(id: notification.id) // records a persisted tombstone
        store.replaceNotificationsForTesting([]) // the entry leaves the store entirely

        // The behavior-test analogue of a Mac relaunch: drop the in-memory ring
        // so the next reconcile must re-read the persisted copy.
        store.reloadDismissedTombstonesForTesting()

        #expect(
            store.reconcileHandledNotificationIDs(deliveredIDs: [notification.id])
                == [notification.id.uuidString]
        )
    }

    /// Superseded phone-banner dismissals are deferred behind the (throttled)
    /// replacement push: the buffer must accumulate ids across throttled
    /// supersedes, dedupe replays, and hand everything over exactly once when
    /// the replacement push finally goes out.
    @Test func supersededPhoneDismissBufferAccumulatesAndFlushesOnce() {
        var buffer = SupersededPhoneDismissBuffer()
        let key = SupersededPhoneDismissBuffer.key(tabId: UUID(), surfaceId: UUID())

        buffer.stash(ids: ["a"], forKey: key)
        buffer.stash(ids: ["b", "a"], forKey: key) // replayed "a" kept once

        #expect(buffer.flush(forKey: key) == ["a", "b"])
        #expect(buffer.flush(forKey: key) == [])
    }

    @Test func supersededPhoneDismissBufferIsBoundedAndPerKey() {
        var buffer = SupersededPhoneDismissBuffer()
        let hot = SupersededPhoneDismissBuffer.key(tabId: UUID(), surfaceId: UUID())
        let other = SupersededPhoneDismissBuffer.key(tabId: UUID(), surfaceId: nil)

        buffer.stash(ids: (0..<70).map { "n-\($0)" }, forKey: hot)
        buffer.stash(ids: ["x"], forKey: other)

        let flushed = buffer.flush(forKey: hot)
        #expect(flushed.count == SupersededPhoneDismissBuffer.capacityPerKey)
        #expect(flushed.first == "n-6") // oldest evicted past the cap
        #expect(flushed.last == "n-69")
        #expect(buffer.flush(forKey: other) == ["x"]) // keys independent
    }

    /// Tab-scoped read/clear operations must drain every surface key under the
    /// tab (after them no surface in the tab has an unread entry), while other
    /// tabs' stashes stay put; clear-all/mark-all-read drain everything.
    @Test func supersededPhoneDismissBufferTabAndGlobalFlush() {
        var buffer = SupersededPhoneDismissBuffer()
        let tabA = UUID()
        let tabB = UUID()
        buffer.stash(ids: ["a1"], forKey: SupersededPhoneDismissBuffer.key(tabId: tabA, surfaceId: UUID()))
        buffer.stash(ids: ["a2"], forKey: SupersededPhoneDismissBuffer.key(tabId: tabA, surfaceId: nil))
        buffer.stash(ids: ["b1"], forKey: SupersededPhoneDismissBuffer.key(tabId: tabB, surfaceId: UUID()))

        #expect(buffer.flush(matchingTabId: tabA).sorted() == ["a1", "a2"])
        #expect(buffer.flush(matchingTabId: tabA) == []) // drained exactly once

        #expect(buffer.flushAll() == ["b1"])
        #expect(buffer.flushAll() == [])
    }

    /// The phone badge counts unread notification entries only. Workspace-level
    /// manual unread indicators feed the Mac Dock badge but have no phone banner,
    /// so they must not inflate the phone count.
    @Test func phoneBadgeCountsNotificationEntriesNotWorkspaceIndicators() throws {
        let store = TerminalNotificationStore.shared
        let previousNotifications = store.notifications
        defer { store.replaceNotificationsForTesting(previousNotifications) }

        let tabId = UUID()
        store.replaceNotificationsForTesting([]) // also clears manual unread state
        let dockCountBefore = store.unreadCount

        store.markUnread(forTabId: tabId) // workspace indicator, no entry
        defer { store.markRead(forTabId: tabId) }

        #expect(store.unreadCount == dockCountBefore + 1)
        #expect(store.unreadNotificationCount == 0)
    }
}
