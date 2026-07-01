import Combine
import Foundation
import Observation
import Testing

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceSidebarObservationTests {
    @Test func sidebarObservationPublisherEmitsForLateStatusSubscriber() {
        let workspace = Workspace()
        workspace.statusEntries["test_probe"] = SidebarStatusEntry(
            key: "test_probe",
            value: "VISIBLE?",
            icon: "star.fill",
            color: "#FF0000",
            priority: 200
        )

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    @Test func agentRuntimeObservationChangesWhenAgentPIDMakesExistingStatusVisible() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "codex" },
            "Structured agent statuses stay hidden until a live agent runtime owns the status key."
        )

        let generationBeforeRecord = workspace.sidebarAgentRuntimeObservation.changeGeneration
        var workspaceWillChangeCount = 0
        let objectWillChangeCancellable = workspace.objectWillChange.sink {
            workspaceWillChangeCount += 1
        }
        defer { objectWillChangeCancellable.cancel() }

        workspace.recordAgentPID(
            key: "codex.session-b",
            pid: 12_345,
            panelId: panelId,
            refreshPorts: false
        )

        #expect(
            workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "codex" },
            "Recording the agent PID makes the existing Running status visible."
        )
        #expect(
            workspace.sidebarAgentRuntimeObservation.changeGeneration > generationBeforeRecord,
            "Agent PID ownership changes must notify the sidebar row runtime observation stream."
        )
        #expect(
            workspaceWillChangeCount == 0,
            "Agent PID ownership is sidebar presentation state and must not broadly invalidate Workspace observers."
        )
    }

    @Test func terminalAgentContextDoesNotObserveAgentRuntimeMaps() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])
        let changeFlag = ObservationChangeFlag()

        withObservationTracking {
            _ = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        } onChange: {
            changeFlag.mark()
        }

        workspace.recordAgentPID(
            key: "codex.session-c",
            pid: 12_346,
            panelId: panelId,
            refreshPorts: false
        )

        #expect(
            changeFlag.fired == false,
            "Terminal content must not subscribe to sidebar-only agent runtime map churn."
        )
    }

    @Test func sidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    @Test func sidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        #expect(
            publishCount == 0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }
}

// Mutable flag captured by Observation's Sendable onChange closure in this test.
private final class ObservationChangeFlag: @unchecked Sendable {
    private(set) var fired = false

    func mark() {
        fired = true
    }
}
