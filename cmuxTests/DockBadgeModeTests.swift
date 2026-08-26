import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock badge modes")
@MainActor
struct DockBadgeModeTests {
    private func label(
        mode: DockBadgeMode,
        unread: Int = 0,
        waiting: Int = 0,
        ready: Int = 0
    ) -> String? {
        TerminalNotificationStore.dockBadgeLabel(
            unreadCount: unread,
            isEnabled: true,
            runTag: nil,
            mode: mode,
            needsInputCount: waiting,
            idleCount: ready
        )
    }

    @Test func notificationsModeIsUnchanged() {
        #expect(label(mode: .notifications, unread: 11) == "11")
        #expect(label(mode: .notifications, unread: 0) == nil)
        #expect(label(mode: .notifications, unread: 250) == "99+")
        // Agent counts are irrelevant in this mode.
        #expect(label(mode: .notifications, unread: 0, waiting: 4, ready: 9) == nil)
    }

    @Test func waitingModeCountsOnlyBlockedPanes() {
        #expect(label(mode: .agentsWaiting, unread: 11, waiting: 3) == "3")
        // Unread notifications must not leak into the count: reading a
        // notification does not answer the agent.
        #expect(label(mode: .agentsWaiting, unread: 11, waiting: 0) == nil)
    }

    @Test func waitingAndReadyShowsBothHalves() {
        #expect(label(mode: .agentsWaitingAndReady, waiting: 2, ready: 7) == "2/7")
        // A zero on either side still reads: hiding it would throw away the
        // half that is non-zero.
        #expect(label(mode: .agentsWaitingAndReady, waiting: 0, ready: 4) == "0/4")
        #expect(label(mode: .agentsWaitingAndReady, waiting: 3, ready: 0) == "3/0")
        #expect(label(mode: .agentsWaitingAndReady, waiting: 0, ready: 0) == nil)
    }

    @Test func disablingTheBadgeWinsOverEveryMode() {
        for mode in DockBadgeMode.allCases {
            #expect(
                TerminalNotificationStore.dockBadgeLabel(
                    unreadCount: 5,
                    isEnabled: false,
                    runTag: nil,
                    mode: mode,
                    needsInputCount: 5,
                    idleCount: 5
                ) == nil
            )
        }
    }

    @Test func modeDefaultsToNotificationsAndRejectsGarbage() throws {
        let suiteName = "DockBadgeMode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(DockBadgeMode.current(defaults: defaults) == .notifications)
        defaults.set("agentsWaiting", forKey: DockBadgeMode.defaultsKey)
        #expect(DockBadgeMode.current(defaults: defaults) == .agentsWaiting)
        defaults.set("nonsense", forKey: DockBadgeMode.defaultsKey)
        #expect(DockBadgeMode.current(defaults: defaults) == .notifications)
    }
}
