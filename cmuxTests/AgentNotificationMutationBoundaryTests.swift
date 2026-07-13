import CmuxControlSocket
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    @Test("A stale source clear preserves a destination-confined stored notification")
    func staleSourceClearPreservesDestinationConfinedStoredNotification() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        try movePanel(fixture)

        fixture.store.addNotification(
            tabId: fixture.destination.id,
            surfaceId: fixture.panelId,
            title: "Relay",
            subtitle: "Completed",
            body: "Authorized only for destination",
            retargetsToLiveSurfaceOwner: false
        )

        fixture.store.clearNotifications(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId
        )

        let recorded = fixture.store.notifications.filter {
            $0.body == "Authorized only for destination"
        }
        #expect(recorded.map(\.tabId) == [fixture.destination.id])
        #expect(recorded.first?.surfaceId == fixture.panelId)
        #expect(recorded.first?.retargetsToLiveSurfaceOwner == false)
    }

    @Test("A queued workspace clear lets a moved surface notification drain first")
    func queuedWorkspaceClearPreservesNotificationMovedToAnotherWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Queued before move and clear"
        )
        try movePanel(fixture)
        bus.enqueueClearNotifications(forTabId: fixture.source.id)

        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        let recorded = fixture.store.notifications.filter {
            $0.body == "Queued before move and clear"
        }
        #expect(recorded.map(\.tabId) == [fixture.destination.id])
        #expect(recorded.first?.surfaceId == fixture.panelId)
    }

    @Test("A queued clear preserves policy work registered after its barrier")
    func queuedClearPreservesNewerInFlightPolicyDelivery() async throws {
        let fixture = try makeFixture(policyHookCommand: "cat")
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        bus.enqueueClearNotifications(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId
        )
        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Registered after clear"
        )

        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()
        await waitForNotification(in: fixture.store)

        #expect(fixture.store.notifications.map(\.body) == ["Registered after clear"])
    }

    @Test("Agent runtime mutations follow a pane that moves before queue drain")
    func queuedAgentRuntimeMutationsResolveLivePanelOwner() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: 43_210
        )
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            panelID: fixture.panelId
        )

        try movePanel(fixture)
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"] == nil)
        #expect(fixture.destination.statusEntries["claude_code"]?.value == "Running")
        #expect(fixture.destination.agentPIDs["claude_code"] == 43_210)
        #expect(
            fixture.destination.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == .running
        )
    }
}
