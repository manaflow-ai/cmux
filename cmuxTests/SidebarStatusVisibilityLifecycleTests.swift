import Foundation
import Testing

// The app module is renamed per tagged build, so resolve whichever is present.
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the lifecycle-based admission of reserved agent status keys.
///
/// The sidebar hides reserved agent status chips (e.g. `claude_code`) unless
/// an agent PID proves the agent is alive. A remote agent's process lives on
/// another host, so no PID is ever recorded and its Running chip was stored
/// but permanently invisible. The admission under test accepts a live
/// hook-reported lifecycle as the liveness proof instead — without changing
/// what the PID pass admits for local agents.
@Suite("SidebarStatusVisibilityLifecycle")
struct SidebarStatusVisibilityLifecycleTests {
    private let panelId = UUID()
    private let reservedKey = "claude_code"

    @Test func liveLifecycleAdmitsStoredReservedKey() {
        for lifecycle in [AgentHibernationLifecycleState.running, .needsInput] {
            let admitted = Workspace.agentStatusKeysAdmittedByLifecycle(
                lifecycleStatesByPanelId: [panelId: [reservedKey: lifecycle]],
                livePanelIds: [panelId],
                storedStatusKeys: [reservedKey]
            )
            #expect(admitted == [panelId: [reservedKey]], "\(lifecycle)")
        }
    }

    @Test func idleOrUnknownLifecycleAdmitsNothing() {
        for lifecycle in [AgentHibernationLifecycleState.idle, .unknown] {
            let admitted = Workspace.agentStatusKeysAdmittedByLifecycle(
                lifecycleStatesByPanelId: [panelId: [reservedKey: lifecycle]],
                livePanelIds: [panelId],
                storedStatusKeys: [reservedKey]
            )
            #expect(admitted.isEmpty, "\(lifecycle)")
        }
    }

    @Test func deadPanelAdmitsNothing() {
        // A lifecycle left behind by a closed pane must not resurrect a chip.
        let admitted = Workspace.agentStatusKeysAdmittedByLifecycle(
            lifecycleStatesByPanelId: [panelId: [reservedKey: .running]],
            livePanelIds: [],
            storedStatusKeys: [reservedKey]
        )
        #expect(admitted.isEmpty)
    }

    @Test func missingStoredEntryAdmitsNothing() {
        // Admission only reveals an already-stored chip; it never invents one.
        let admitted = Workspace.agentStatusKeysAdmittedByLifecycle(
            lifecycleStatesByPanelId: [panelId: [reservedKey: .running]],
            livePanelIds: [panelId],
            storedStatusKeys: []
        )
        #expect(admitted.isEmpty)
    }

    @Test func unreservedKeysAreNotAdmitted() {
        // Non-reserved keys bypass the reserved-key filter entirely; the
        // lifecycle admission must not start owning them.
        let admitted = Workspace.agentStatusKeysAdmittedByLifecycle(
            lifecycleStatesByPanelId: [panelId: ["my-custom-status": .running]],
            livePanelIds: [panelId],
            storedStatusKeys: ["my-custom-status"]
        )
        #expect(admitted.isEmpty)
    }
}
