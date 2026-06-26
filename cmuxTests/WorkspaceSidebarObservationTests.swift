import Combine
import Foundation
import Testing

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace sidebar observation", .serialized)
struct WorkspaceSidebarObservationTests {
    @Test
    func sidebarObservationPublisherEmitsForLateStatusSubscriber() {
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

    @Test
    func sidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
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

    @Test
    func sidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
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

    @Test
    func sidebarObservationPublisherEmitsForAgentLifecycleOnlyChange() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .needsInput)

        #expect(
            publishCount > 0,
            "Agent lifecycle changes must refresh extension sidebar status dots even when no visible metadata text changes"
        )
    }

    @Test
    func sidebarStatusIndicatorPrioritizesNeedsInputOverRunning() {
        #expect(
            AgentHibernationLifecycleState.dominantForStatusIndicator(
                in: [.running, .needsInput],
                fallback: .unknown
            ) == .needsInput
        )
    }

    @Test
    func agentStatusIndicatorTextMatchesDominantLifecycleKey() {
        let workspace = Workspace()
        let runningPanelId = UUID()
        let waitingPanelId = UUID()
        workspace.agentLifecycleStatesByPanelId[runningPanelId] = ["codex": .running]
        workspace.agentLifecycleStatesByPanelId[waitingPanelId] = ["claude_code": .needsInput]
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Running")
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Needs input")

        let snapshot = workspace.agentStatusIndicatorSnapshot()

        #expect(snapshot?.state == .needsInput)
        #expect(snapshot?.text == "Needs input")
    }

    @Test
    func agentStatusIndicatorTextIgnoresAmbiguousSharedStatusKey() {
        let workspace = Workspace()
        let runningPanelId = UUID()
        let waitingPanelId = UUID()
        workspace.agentLifecycleStatesByPanelId[runningPanelId] = ["codex": .running]
        workspace.agentLifecycleStatesByPanelId[waitingPanelId] = ["codex": .needsInput]
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Running")

        let snapshot = workspace.agentStatusIndicatorSnapshot()

        #expect(snapshot?.state == .needsInput)
        #expect(snapshot?.text == nil)
    }
}
