import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AgentLifecycleEventTests {
    @Test
    func lifecycleMutationPublishesSemanticStateWithSessionIdentity() throws {
        let fixture = try Fixture()

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-one"
        )

        let event = try #require(fixture.agentEvents().only)
        let payload = try #require(event["payload"] as? [String: Any])
        #expect(event["name"] as? String == "agent.state.changed")
        #expect(event["category"] as? String == "agent")
        #expect(event["source"] as? String == "agent.lifecycle")
        #expect(event["workspace_id"] as? String == fixture.workspace.id.uuidString)
        #expect(event["surface_id"] as? String == fixture.surfaceID.uuidString)
        #expect(payload["agent"] as? String == "codex")
        #expect(payload["state"] as? String == "running")
        #expect(payload["session_id"] as? String == "session-one")
        #expect(CmuxEventBus.int64(payload["revision"]) == 1)
    }

    @Test
    func replacementPublishesOldExitBeforeNewOccupantState() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-old"
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-new"
        )

        let payloads = fixture.agentEvents(after: baselineSequence)
            .compactMap { $0["payload"] as? [String: Any] }
        #expect(payloads.count == 2)
        #expect(payloads.compactMap { $0["state"] as? String } == ["exit", "idle"])
        #expect(payloads.compactMap { $0["session_id"] as? String } == ["session-old", "session-new"])
        #expect(payloads.compactMap { CmuxEventBus.int64($0["revision"]) } == [1, 2])
    }

    @Test
    func staleSessionTeardownCannotClearReplacementLifecycle() throws {
        let fixture = try Fixture()
        fixture.workspace.recordAgentPID(
            key: "codex.session-old",
            pid: getpid(),
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-old"
        )
        fixture.workspace.recordAgentPID(
            key: "codex.session-new",
            pid: getpid(),
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-new"
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        let didClear = fixture.workspace.clearAgentPID(
            key: "codex.session-old",
            panelId: fixture.surfaceID,
            clearStatus: true,
            refreshPorts: false,
            expectedLifecycleSessionID: "session-old"
        )

        #expect(!didClear)
        #expect(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]?.sessionID
                == "session-new"
        )
        #expect(
            fixture.workspace.agentLifecycleStatesByPanelId[fixture.surfaceID]?["codex"] == .idle
        )
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)
    }

    private struct Fixture {
        let workspace: Workspace
        let surfaceID: UUID

        init() throws {
            workspace = Workspace()
            surfaceID = try #require(workspace.focusedPanelId)
        }

        func agentEvents(after sequence: Int64? = nil) -> [[String: Any]] {
            CmuxEventBus.shared.retainedSnapshot().filter { event in
                event["name"] as? String == "agent.state.changed"
                    && event["surface_id"] as? String == surfaceID.uuidString
                    && sequence.map {
                        (CmuxEventBus.int64(event["seq"]) ?? 0) > $0
                    } != false
            }
        }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
