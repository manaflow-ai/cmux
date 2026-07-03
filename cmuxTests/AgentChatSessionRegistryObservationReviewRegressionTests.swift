import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryObservationReviewRegressionTests {
    @Test func mobileChatObserverPrefersRealClaudeChildForSameSession() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 101,
                    parentPID: 10,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                ),
                topProcess(
                    pid: 202,
                    parentPID: 101,
                    name: "claude",
                    path: "/Users/example/.claude/local/claude",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 101),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                switch pid {
                case 101:
                    CmuxTopProcessArguments(
                        arguments: [
                            "node",
                            "/Users/example/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js",
                        ],
                        environment: [
                            "CMUX_AGENT_LAUNCH_KIND": "claude",
                            "CLAUDE_CODE_SESSION_ID": sessionID,
                            "CMUX_AGENT_LAUNCH_CWD": "/Users/example/project",
                        ]
                    )
                case 202:
                    CmuxTopProcessArguments(
                        arguments: ["claude"],
                        environment: [
                            "CLAUDE_CODE_SESSION_ID": sessionID,
                            "CMUX_AGENT_LAUNCH_CWD": "/Users/example/project",
                        ]
                    )
                default:
                    nil
                }
            },
            codexRolloutPath: { _ in nil }
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == sessionID)
        #expect(session.pid == 202)
    }

    private func topProcess(
        pid: Int,
        parentPID: Int,
        name: String,
        path: String?,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: name,
            path: path,
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: surfaceID,
            cmuxAttributionReason: "test",
            processGroupID: pid,
            terminalProcessGroupID: pid,
            cpuPercent: 0,
            residentBytes: 1,
            virtualBytes: 1,
            threadCount: 1
        )
    }
}
