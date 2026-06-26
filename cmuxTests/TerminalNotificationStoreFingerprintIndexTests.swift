import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for issue #5831: the session-autosave fingerprint and
/// snapshot build call `TerminalNotificationStore.notifications(forTabId:surfaceId:)`
/// once per workspace plus once per panel. That accessor used to run a full
/// `notifications.filter` over the entire store on every call, so a tick was
/// O(workspaces × panels × notifications) on the main thread every 8s. It is now
/// an O(1) lookup into a precomputed `(tabId, surfaceId)` index.
///
/// The risky part of that change is that the index must reproduce
/// `TerminalNotification.matches(tabId:surfaceId:)` exactly — same notifications,
/// same order, including the surfaceId/panelId cross-match and read entries.
/// These tests assert the indexed lookup is byte-identical to an independent
/// `matches`-based reference filter across those combinations.
///
/// Serialized because every case mutates the `TerminalNotificationStore.shared`
/// singleton.
@MainActor
@Suite(.serialized)
struct TerminalNotificationStoreFingerprintIndexTests {
    private func makeNotification(
        tab: UUID,
        surface: UUID?,
        panel: UUID?,
        read: Bool
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: surface,
            panelId: panel,
            title: "title",
            subtitle: "subtitle",
            body: "body",
            createdAt: Date(),
            isRead: read
        )
    }

    @Test
    func indexedLookupMatchesFilterSemantics() {
        let store = TerminalNotificationStore.shared
        let original = store.notifications
        defer { store.replaceNotificationsForTesting(original) }

        let tabA = UUID()
        let tabB = UUID()
        let surface1 = UUID()
        let surface2 = UUID()
        let panelX = UUID()

        let injected: [TerminalNotification] = [
            // Tab-level (no surface, no panel) — matches only the nil-surface query.
            makeNotification(tab: tabA, surface: nil, panel: nil, read: false),
            // Tab-level but read — the accessor returns read entries too.
            makeNotification(tab: tabA, surface: nil, panel: nil, read: true),
            // Surface only.
            makeNotification(tab: tabA, surface: surface1, panel: nil, read: false),
            // Surface plus a *different* panel — bucketed under both surface1 and panelX.
            makeNotification(tab: tabA, surface: surface1, panel: panelX, read: false),
            // Panel only (no surface) — matches the panel query, never the nil query.
            makeNotification(tab: tabA, surface: nil, panel: panelX, read: false),
            // surfaceId == panelId — must not be double-counted.
            makeNotification(tab: tabA, surface: surface2, panel: surface2, read: false),
            // Same surface id but a different tab — must not leak across tabs.
            makeNotification(tab: tabB, surface: surface1, panel: nil, read: false),
        ]
        store.replaceNotificationsForTesting(injected)

        let tabs = [tabA, tabB, UUID()]
        let surfaces: [UUID?] = [nil, surface1, surface2, panelX, UUID()]
        for tab in tabs {
            for surface in surfaces {
                let expected = injected.filter { $0.matches(tabId: tab, surfaceId: surface) }
                let actual = store.notifications(forTabId: tab, surfaceId: surface)
                #expect(
                    actual == expected,
                    "notifications(forTabId:surfaceId:) diverged from matches() filter "
                        + "for tab=\(tab) surface=\(String(describing: surface))"
                )
            }
        }
    }

    @Test
    func indexedLookupPreservesArrayOrder() {
        let store = TerminalNotificationStore.shared
        let original = store.notifications
        defer { store.replaceNotificationsForTesting(original) }

        let tab = UUID()
        let surface = UUID()
        // Three notifications on the same (tab, surface) so order is observable.
        let injected: [TerminalNotification] = [
            makeNotification(tab: tab, surface: surface, panel: nil, read: false),
            makeNotification(tab: tab, surface: surface, panel: nil, read: true),
            makeNotification(tab: tab, surface: surface, panel: nil, read: false),
        ]
        store.replaceNotificationsForTesting(injected)

        let actual = store.notifications(forTabId: tab, surfaceId: surface)
        #expect(actual.map(\.id) == injected.map(\.id))
    }

    @Test
    func emptyStoreReturnsEmptyForAnyQuery() {
        let store = TerminalNotificationStore.shared
        let original = store.notifications
        defer { store.replaceNotificationsForTesting(original) }

        store.replaceNotificationsForTesting([])
        #expect(store.notifications(forTabId: UUID(), surfaceId: nil).isEmpty)
        #expect(store.notifications(forTabId: UUID(), surfaceId: UUID()).isEmpty)
    }
}
