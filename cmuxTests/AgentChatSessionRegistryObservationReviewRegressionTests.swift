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

    @Test func mobileChatObserverIgnoresInheritedLaunchKindOnChildTool() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 101,
                    parentPID: 10,
                    name: "claude",
                    path: "/opt/homebrew/bin/claude",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    processGroupID: 101,
                    terminalProcessGroupID: 101
                ),
                topProcess(
                    pid: 202,
                    parentPID: 101,
                    name: "git",
                    path: "/usr/bin/git",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    processGroupID: 101,
                    terminalProcessGroupID: 101
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 102),
            includesProcessDetails: true
        )

        let details: (Int) -> CmuxTopProcessArguments? = { pid in
            switch pid {
            case 101:
                CmuxTopProcessArguments(
                    arguments: ["claude"],
                    environment: ["CLAUDE_CODE_SESSION_ID": sessionID]
                )
            case 202:
                CmuxTopProcessArguments(
                    arguments: ["git", "status"],
                    environment: [
                        "CMUX_AGENT_LAUNCH_KIND": "claude",
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                    ]
                )
            default:
                nil
            }
        }

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: details,
            codexRolloutPath: { _ in nil }
        )
        let livePID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            matchingSessionIDs: [sessionID],
            processArgumentsAndEnvironment: details
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == sessionID)
        #expect(session.pid == 101)
        #expect(livePID == 101)
    }

    @Test func mobileChatObserverDetectsClaudeExeRuntimeProcess() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "1258bb73-b1b8-469e-910a-61266f4dfc44"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 96441,
                    parentPID: 93888,
                    name: "claude.exe",
                    path: "/Users/example/.local/share/claude/versions/2.1.199/claude.exe",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 1258),
            includesProcessDetails: true
        )
        let details: (Int) -> CmuxTopProcessArguments? = { pid in
            guard pid == 96441 else { return nil }
            return CmuxTopProcessArguments(
                arguments: ["claude.exe"],
                environment: [
                    "CLAUDE_CODE_SESSION_ID": sessionID,
                    "PWD": "/Users/example/project",
                ]
            )
        }

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: details,
            codexRolloutPath: { _ in nil }
        )
        let livePID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            matchingSessionIDs: [sessionID],
            processArgumentsAndEnvironment: details
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == sessionID)
        #expect(session.agentKind == .claude)
        #expect(session.workspaceID == workspaceID.uuidString)
        #expect(session.surfaceID == surfaceID.uuidString)
        #expect(session.pid == 96441)
        #expect(session.workingDirectory == "/Users/example/project")
        #expect(livePID == 96441)
    }

    @Test func mobileChatObserverCreatesPendingClaudeExeWhenSessionIdentityIsUnavailable() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 54045,
                    parentPID: 51297,
                    name: "claude.exe",
                    path: "/Users/example/.local/share/claude/versions/2.1.199/claude.exe",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 540),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { _ in nil },
            codexRolloutPath: { _ in nil }
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID.uuidString))
        #expect(session.agentKind == .claude)
        #expect(session.workspaceID == workspaceID.uuidString)
        #expect(session.surfaceID == surfaceID.uuidString)
        #expect(session.pid == 54045)
        #expect(session.workingDirectory == nil)
    }

    private func topProcess(
        pid: Int,
        parentPID: Int,
        name: String,
        path: String?,
        workspaceID: UUID,
        surfaceID: UUID,
        processGroupID: Int? = nil,
        terminalProcessGroupID: Int? = nil
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
            processGroupID: processGroupID ?? pid,
            terminalProcessGroupID: terminalProcessGroupID ?? pid,
            cpuPercent: 0,
            residentBytes: 1,
            virtualBytes: 1,
            threadCount: 1
        )
    }
}
