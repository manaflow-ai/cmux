import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct TaskManagerCodingAgentInstanceTests {
    private let workspaceID = UUID(uuidString: "7F587C98-0069-4605-B066-F6FB941D54B4")!
    private let surfaceID = UUID(uuidString: "38457A72-7D87-40FC-8ED5-899B59572FD0")!

    @Test func codingAgentRowsJumpToTheWorkspaceAndSurfaceRunningThem() throws {
        let snapshot = CmuxTaskManagerSnapshot(payload: [
            "sample": ["sampled_at": "2026-09-28T12:00:00Z"],
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
                            "workspace_ref": "workspace:1",
                            "surface_id": surfaceID.uuidString,
                            "surface_ref": "surface:1",
                            "surface_type": "terminal",
                            "resources": resources(pids: [101]),
                        ],
                    ],
                ],
            ],
            "windows": [windowPayload()],
        ])

        let aggregate = try #require(snapshot.agentRows.first)
        #expect(aggregate.kind == .codingAgentAggregate)
        #expect(aggregate.level == 0)
        #expect(!aggregate.canViewWorkspace)

        let instance = try #require(snapshot.agentRows.dropFirst().first)
        #expect(snapshot.agentRows.count == 2)
        #expect(instance.level == 1)
        #expect(instance.title == "Fix the login flow")
        #expect(instance.detail.hasPrefix("claude: refactor auth"))
        #expect(instance.workspaceId == workspaceID)
        #expect(instance.surfaceId == surfaceID)
        #expect(instance.terminalSurfaceId == surfaceID)
        #expect(instance.canViewWorkspace)
        #expect(instance.canViewTerminal)
        #expect(instance.agentAssetName == "AgentIcons/Claude")
        #expect(instance.resources.processIds == [101])
    }

    private func resources(pids: [Int]) -> [String: Any] {
        [
            "cpu_percent": 2.0,
            "resident_bytes": 512,
            "process_count": pids.count,
            "pids": pids,
        ]
    }

    private func windowPayload() -> [String: Any] {
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
        ]
    }
}
