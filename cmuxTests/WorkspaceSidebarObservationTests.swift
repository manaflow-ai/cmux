import Foundation
import XCTest

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceSidebarObservationTests: XCTestCase {
    func testSidebarObservationPublisherEmitsForLateStatusSubscriber() {
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

        XCTAssertGreaterThan(
            publishCount,
            0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    func testSidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertGreaterThan(
            publishCount,
            0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    func testSidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        XCTAssertEqual(
            publishCount,
            0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }

    func testSidebarObservationPublisherEmitsForAgentLifecycleChanges() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        XCTAssertEqual(
            publishCount,
            1,
            "Agent lifecycle changes must repaint the sidebar row so the active-agent spinner updates."
        )
    }

    func testSidebarObservationPublisherIgnoresLifecycleChurnWithUnchangedRunningCount() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        // Non-running churn on another key leaves the visible running count at
        // 1, so the row must not repaint (the observation state reduces to the
        // count before removeDuplicates()).
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .idle)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)

        XCTAssertEqual(
            publishCount,
            0,
            "Lifecycle churn that leaves the running-agent count unchanged must not invalidate sidebar rows."
        )
    }

    func testClearAgentLifecycleWithNilPanelClearsKeySetOnSpecificPanel() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)
        XCTAssertEqual(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ),
            1
        )

        // The workspace-scoped `cmux workspace loading off` path clears with a
        // nil panel id; it must remove the key even though `on` targeted a
        // specific panel (the cross-surface off bug).
        XCTAssertTrue(workspace.clearAgentLifecycle(key: "manual", panelId: nil))
        XCTAssertEqual(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ),
            0
        )
    }

    func testActiveCodingAgentCountOnlyCountsRunningAgents() {
        let firstPanelId = UUID()
        let secondPanelId = UUID()

        let count = SidebarAgentActivitySummary.activeCodingAgentCount(
            statesByPanelId: [
                firstPanelId: [
                    "codex": .running,
                    "claude_code": .idle,
                    "gemini": .needsInput,
                ],
                secondPanelId: [
                    "opencode": .running,
                    "kiro": .unknown,
                ],
            ]
        )

        XCTAssertEqual(count, 2)
    }
}
