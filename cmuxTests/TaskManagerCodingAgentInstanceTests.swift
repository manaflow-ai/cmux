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

    @Test func agentProcessesGroupBySurfaceAndSkipUnattributedProcesses() throws {
        let otherSurfaceID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(pid: 101, residentBytes: 100),
                process(pid: 102, residentBytes: 200),
                process(pid: 103, residentBytes: 400),
                process(pid: 104, residentBytes: 800),
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        let instances = snapshot.codingAgentInstancePayloads(
            pids: [101, 102, 103, 104],
            attributionByPID: [
                101: attribution(surfaceID: surfaceID),
                102: attribution(surfaceID: surfaceID),
                103: attribution(surfaceID: otherSurfaceID),
            ]
        )

        #expect(instances.count == 2)
        let first = try #require(instances.first { $0["surface_id"] as? String == surfaceID.uuidString })
        let firstResources = try #require(first["resources"] as? [String: Any])
        #expect(first["workspace_id"] as? String == workspaceID.uuidString)
        #expect(firstResources["pids"] as? [Int] == [101, 102])
        #expect(firstResources["resident_bytes"] as? Int64 == 300)
        let firstProcesses = try #require(first["processes"] as? [[String: Any]])
        #expect(firstProcesses.compactMap { $0["pid"] as? Int } == [101, 102])
        #expect(firstProcesses.compactMap { $0["name"] as? String } == ["claude", "claude"])
        let second = try #require(instances.first { $0["surface_id"] as? String == otherSurfaceID.uuidString })
        let secondResources = try #require(second["resources"] as? [String: Any])
        #expect(secondResources["pids"] as? [Int] == [103])
    }

    @Test func aggregatePayloadsGainInstancesWithoutChangingTotals() throws {
        let snapshot = CmuxTopProcessSnapshot(
            processes: [process(pid: 101, residentBytes: 100)],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        let aggregate: [String: Any] = [
            "id": "claude",
            "display_name": "Claude Code",
            "resources": resources(pids: [101]),
        ]
        let payloads = snapshot.codingAgentPayloads(
            [aggregate],
            attributingInstancesWith: [101: attribution(surfaceID: surfaceID)]
        )

        let payload = try #require(payloads.first)
        let instances = try #require(payload["instances"] as? [[String: Any]])
        let totals = try #require(payload["resources"] as? [String: Any])
        #expect(instances.count == 1)
        #expect(totals["pids"] as? [Int] == [101])
    }

    @Test func agentRowNamesThePIDAndProcessNameActivityMonitorShows() throws {
        let detail = try #require(CmuxTaskManagerSnapshot.processIdentityDetail([
            ["pid": 61879, "name": "2.1.283"],
        ]))
        #expect(detail.contains("61879"))
        #expect(detail.contains("2.1.283"))

        let unnamed = try #require(CmuxTaskManagerSnapshot.processIdentityDetail([
            ["pid": 61879, "name": "pid-61879"],
        ]))
        #expect(!unnamed.contains("pid-"))

        let crowded = (1...4).map { ["pid": $0 + 100, "name": "claude"] as [String: Any] }
        #expect(CmuxTaskManagerSnapshot.processIdentityDetail(crowded) == nil)
        #expect(CmuxTaskManagerSnapshot.processIdentityDetail([]) == nil)
    }

    private func process(pid: Int, residentBytes: Int64) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: "claude",
            path: "/usr/local/bin/claude",
            ttyDevice: nil,
            cmuxWorkspaceID: nil,
            cmuxSurfaceID: nil,
            cmuxAttributionReason: nil,
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: residentBytes,
            virtualBytes: residentBytes,
            threadCount: 1
        )
    }

    private func attribution(surfaceID: UUID) -> CmuxTopProcessAttribution {
        CmuxTopProcessAttribution(
            workspaceID: workspaceID,
            workspaceRef: "workspace:1",
            paneID: nil,
            paneRef: nil,
            surfaceID: surfaceID,
            surfaceRef: nil,
            surfaceType: "terminal",
            reason: "surface-process-tree"
        )
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
