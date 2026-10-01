import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct TaskManagerAgentStatusTests {
    private let workspaceID = UUID(uuidString: "7F587C98-0069-4605-B066-F6FB941D54B4")!
    private let surfaceID = UUID(uuidString: "38457A72-7D87-40FC-8ED5-899B59572FD0")!
    private let hibernatedSurfaceID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private let sampledAt = "2026-09-28T12:00:00Z"

    @Test(arguments: [
        ("running", nil, CmuxTaskManagerAgentStatus.State.running),
        ("needsInput", nil, .needsInput),
        ("needs-input", nil, .needsInput),
        ("idle", nil, .idle),
        ("hibernated", nil, .hibernated),
        ("unknown", "Needs input", .needsInput),
        ("unknown", "Idle", .idle),
        ("unknown", "Thinking about it", .unknown),
        (nil, nil, .unknown),
    ] as [(String?, String?, CmuxTaskManagerAgentStatus.State)])
    func stateMapsLifecycleThenSidebarText(
        wireValue: String?,
        statusText: String?,
        expected: CmuxTaskManagerAgentStatus.State
    ) {
        #expect(CmuxTaskManagerAgentStatus.State(wireValue: wireValue, statusText: statusText) == expected)
    }

    @Test func waitingStatesReportWholeMinutesAndRunningDoesNot() {
        let now = Date(timeIntervalSince1970: 10_000)
        let since = now.addingTimeInterval(-(12 * 60 + 59))

        let idle = CmuxTaskManagerAgentStatus(state: .idle, since: since, now: now)
        let running = CmuxTaskManagerAgentStatus(state: .running, since: since, now: now)
        let unknownSince = CmuxTaskManagerAgentStatus(state: .needsInput, since: nil, now: now)
        let future = CmuxTaskManagerAgentStatus(state: .idle, since: now.addingTimeInterval(30), now: now)

        #expect(idle.elapsedMinutes == 12)
        #expect(idle.elapsedText?.isEmpty == false)
        #expect(running.elapsedMinutes == nil)
        #expect(running.elapsedText == nil)
        #expect(unknownSince.elapsedMinutes == nil)
        #expect(future.elapsedMinutes == 0)
        #expect(!CmuxTaskManagerAgentStatus.elapsedText(minutes: 0).isEmpty)
    }

    @Test func agentRowsCarryTheirTerminalStateAndOfferClose() throws {
        let snapshot = CmuxTaskManagerSnapshot(payload: payload(agentPanels: [
            [
                "workspace_id": workspaceID.uuidString,
                "surface_id": surfaceID.uuidString,
                "state": "idle",
                "status_text": "Idle",
                "since": "2026-09-28T11:48:00Z",
            ],
        ]))

        let instance = try #require(snapshot.agentRows.first { $0.surfaceId == surfaceID })
        let status = try #require(instance.agentStatus)
        #expect(status.state == .idle)
        #expect(status.elapsedMinutes == 12)
        #expect(instance.canCloseTerminal)

        let aggregate = try #require(snapshot.agentRows.first { $0.kind == .codingAgentAggregate })
        #expect(aggregate.agentStatus == nil)
        #expect(!aggregate.canCloseTerminal)
        #expect(snapshot.rows.allSatisfy { !$0.canCloseTerminal })
    }

    @Test func agentRowWithoutReportedStateHasNoStatusOrClose() throws {
        let snapshot = CmuxTaskManagerSnapshot(payload: payload(agentPanels: []))
        let instance = try #require(snapshot.agentRows.first { $0.surfaceId == surfaceID })

        #expect(instance.agentStatus == nil)
        #expect(!instance.canCloseTerminal)
        #expect(instance.canViewTerminal)
    }

    @Test func hibernatedAgentsAppearUnderTheirProgramWithoutUsage() throws {
        let snapshot = CmuxTaskManagerSnapshot(payload: payload(agentPanels: [
            [
                "workspace_id": workspaceID.uuidString,
                "surface_id": hibernatedSurfaceID.uuidString,
                "state": "hibernated",
                "since": "2026-09-28T10:00:00Z",
                "agent_name": "Claude Code",
            ],
            [
                "workspace_id": workspaceID.uuidString,
                "surface_id": UUID(uuidString: "66666666-6666-6666-6666-666666666666")!.uuidString,
                "state": "hibernated",
                "agent_name": "Codex",
            ],
        ]))

        let ids = snapshot.agentRows.map(\.id)
        let claudeIndex = try #require(ids.firstIndex(of: "codingAgentAggregate:claude"))
        let hibernatedIndex = try #require(snapshot.agentRows.firstIndex { $0.surfaceId == hibernatedSurfaceID })
        #expect(hibernatedIndex > claudeIndex)
        let hibernated = snapshot.agentRows[hibernatedIndex]
        #expect(hibernated.level == 1)
        #expect(hibernated.agentStatus?.state == .hibernated)
        #expect(hibernated.agentStatus?.elapsedMinutes == 120)
        #expect(hibernated.resources.processCount == 0)
        #expect(hibernated.canViewTerminal)
        #expect(hibernated.canCloseTerminal)
        #expect(!hibernated.canKillProcess)
        #expect(hibernated.title == "Fix the login flow")

        let codexTotal = try #require(snapshot.agentRows.first { $0.id == "codingAgentAggregate:hibernated:codex" })
        #expect(codexTotal.title == "Codex")
        #expect(codexTotal.resources.processCount == 0)
    }

    @Test func aRenamedHibernatedAgentStaysUnderItsProgram() throws {
        // The panel reports the program id "claude" but a registration name
        // that differs from the running group's "Claude Code". Grouping by the
        // displayed name would open a second Claude group with no icon.
        let snapshot = CmuxTaskManagerSnapshot(payload: payload(agentPanels: [
            [
                "workspace_id": workspaceID.uuidString,
                "surface_id": hibernatedSurfaceID.uuidString,
                "state": "hibernated",
                "since": "2026-09-28T10:00:00Z",
                "agent_name": "Claude, work laptop",
                "agent_id": "claude",
            ],
        ]))

        let totals = snapshot.agentRows.filter { $0.kind == .codingAgentAggregate }
        #expect(totals.count == 1)
        let total = try #require(totals.first)
        #expect(total.id == "codingAgentAggregate:claude")
        #expect(total.title == "Claude Code")
        #expect(total.agentAssetName == "AgentIcons/Claude")

        let hibernated = try #require(snapshot.agentRows.first { $0.surfaceId == hibernatedSurfaceID })
        #expect(hibernated.level == 1)
        #expect(hibernated.agentStatus?.state == .hibernated)
        #expect(hibernated.agentAssetName == "AgentIcons/Claude")
    }

    @Test func twoHibernatedPanelsOfOneProgramShareOneGroup() throws {
        // Neither panel has a live group to join, so the first creates the
        // group and the second must find it by id instead of adding a third
        // Codex total.
        let secondSurfaceID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let snapshot = CmuxTaskManagerSnapshot(payload: payload(agentPanels: [
            [
                "workspace_id": workspaceID.uuidString,
                "surface_id": hibernatedSurfaceID.uuidString,
                "state": "hibernated",
                "agent_name": "Codex",
                "agent_id": "codex",
            ],
            [
                "workspace_id": workspaceID.uuidString,
                "surface_id": secondSurfaceID.uuidString,
                "state": "hibernated",
                "agent_name": "Codex, review",
                "agent_id": "codex",
            ],
        ]))

        let codexTotals = snapshot.agentRows.filter {
            $0.kind == .codingAgentAggregate && $0.id.contains("codex")
        }
        #expect(codexTotals.count == 1)
        #expect(snapshot.agentRows.contains { $0.surfaceId == hibernatedSurfaceID })
        #expect(snapshot.agentRows.contains { $0.surfaceId == secondSurfaceID })
    }

    @MainActor
    @Test func workspaceReportsLifecycleOverlaysAndSkipsManualLoaders() throws {
        let workspace = Workspace(title: "Tests")
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.taskManagerAgentPanelPayloads().isEmpty)

        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)
        #expect(workspace.taskManagerAgentPanelPayloads().isEmpty)

        workspace.setAgentLifecycle(
            key: FeedCoordinator.attentionStatusKey(forSource: "claude"),
            panelId: panelId,
            lifecycle: .needsInput
        )
        let payloads = workspace.taskManagerAgentPanelPayloads()
        let payload = try #require(payloads.first)
        #expect(payloads.count == 1)
        #expect(payload["surface_id"] as? String == panelId.uuidString)
        #expect(payload["workspace_id"] as? String == workspace.id.uuidString)
        #expect(payload["state"] as? String == AgentHibernationLifecycleState.needsInput.rawValue)
        #expect(CmuxTaskManagerAgentStatus.State(
            wireValue: payload["state"] as? String,
            statusText: nil
        ) == .needsInput)
    }

    private func payload(agentPanels: [[String: Any]]) -> [String: Any] {
        [
            "sample": ["sampled_at": sampledAt],
            "totals": resources(pids: [101]),
            "coding_agents": [
                [
                    "id": "claude",
                    "display_name": "Claude Code",
                    "asset_name": "AgentIcons/Claude",
                    "resources": resources(pids: [101]),
                    "instances": [
                        [
                            "id": "surface:\(surfaceID.uuidString)",
                            "workspace_id": workspaceID.uuidString,
                            "surface_id": surfaceID.uuidString,
                            "surface_type": "terminal",
                            "resources": resources(pids: [101]),
                        ],
                    ],
                ],
            ],
            "agent_panels": agentPanels,
            "windows": [
                [
                    "id": "window-1",
                    "ref": "window:1",
                    "resources": resources(pids: [101]),
                    "workspaces": [
                        [
                            "id": workspaceID.uuidString,
                            "ref": "workspace:1",
                            "title": "Fix the login flow",
                            "resources": resources(pids: [101]),
                            "panes": [
                                [
                                    "id": "pane-1",
                                    "ref": "pane:1",
                                    "resources": resources(pids: [101]),
                                    "surfaces": [
                                        [
                                            "id": surfaceID.uuidString,
                                            "ref": "surface:1",
                                            "type": "terminal",
                                            "title": "claude: refactor auth",
                                            "resources": resources(pids: [101]),
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private func resources(pids: [Int]) -> [String: Any] {
        [
            "cpu_percent": 2.0,
            "resident_bytes": 512,
            "process_count": pids.count,
            "pids": pids,
        ]
    }
}
