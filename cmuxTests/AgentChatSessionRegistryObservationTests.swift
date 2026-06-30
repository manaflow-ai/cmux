import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentChatSessionRegistryObservationTests: XCTestCase {
    func testMobileChatObserverDetectsNodeHostedClaudeFromProcessDetails() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 101,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 100),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                guard pid == 101 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "node",
                        "/Users/example/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js",
                    ],
                    environment: [
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                        "CMUX_AGENT_LAUNCH_CWD": "/Users/example/project",
                    ]
                )
            },
            codexRolloutPath: { _ in nil }
        )

        let session = try XCTUnwrap(observed.first)
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(session.sessionID, sessionID)
        XCTAssertEqual(session.agentKind, .claude)
        XCTAssertEqual(session.workspaceID, workspaceID.uuidString)
        XCTAssertEqual(session.surfaceID, surfaceID.uuidString)
        XCTAssertEqual(session.pid, 101)
        XCTAssertEqual(session.workingDirectory, "/Users/example/project")
    }

    func testMobileChatObserverStillDetectsDirectCodexFromRolloutFile() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "018ff5fe-3f91-79d0-99aa-a6a2d7c17b22"
        let rolloutPath = "/Users/example/.codex/sessions/2026/06/29/rollout-2026-06-29T12-00-00-\(sessionID).jsonl"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 202,
                    name: "codex",
                    path: "/opt/homebrew/bin/codex",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 200),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { _ in nil },
            codexRolloutPath: { pid in pid == 202 ? rolloutPath : nil }
        )

        let session = try XCTUnwrap(observed.first)
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(session.sessionID, sessionID)
        XCTAssertEqual(session.agentKind, .codex)
        XCTAssertEqual(session.workspaceID, workspaceID.uuidString)
        XCTAssertEqual(session.surfaceID, surfaceID.uuidString)
        XCTAssertEqual(session.pid, 202)
        XCTAssertEqual(session.transcriptPath, rolloutPath)
    }

    private func topProcess(
        pid: Int,
        name: String,
        path: String?,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: name,
            path: path,
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: surfaceID,
            cmuxAttributionReason: "test",
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 1,
            virtualBytes: 1,
            threadCount: 1
        )
    }
}
