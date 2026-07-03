import Foundation
import Testing
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryObservationTests {
    @Test func mobileChatObserverDetectsNodeHostedClaudeFromProcessDetails() throws {
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

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == sessionID)
        #expect(session.agentKind == .claude)
        #expect(session.workspaceID == workspaceID.uuidString)
        #expect(session.surfaceID == surfaceID.uuidString)
        #expect(session.pid == 101)
        #expect(session.workingDirectory == "/Users/example/project")
    }

    @Test func mobileChatObserverCreatesPendingClaudeSessionForFreshIdlePrompt() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 111,
                    name: "claude",
                    path: "/opt/homebrew/bin/claude",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 110),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                guard pid == 111 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "claude",
                        "--settings",
                        "{}",
                    ],
                    environment: [
                        "CMUX_AGENT_LAUNCH_CWD": "/Users/example/project",
                    ]
                )
            },
            codexRolloutPath: { _ in nil }
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID.uuidString))
        #expect(session.agentKind == .claude)
        #expect(session.workspaceID == workspaceID.uuidString)
        #expect(session.surfaceID == surfaceID.uuidString)
        #expect(session.pid == 111)
        #expect(session.workingDirectory == "/Users/example/project")
    }

    @MainActor
    @Test func claudeHooksAdoptSameSurfacePendingSession() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(realSessionID).jsonl"

        registry.noteResumeInitiated(
            sessionID: pendingID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: realSessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: transcriptPath,
            cwd: "/Users/example/project",
            ppid: 222,
            receivedAt: Date(timeIntervalSince1970: 120)
        ))

        let record = try #require(registry.record(sessionID: pendingID))
        #expect(registry.record(sessionID: realSessionID) == nil)
        #expect(record.sessionID == pendingID)
        #expect(record.transcriptPath == transcriptPath)
        #expect(record.pid == 222)
        #expect(record.state == .idle)
    }

    @MainActor
    @Test func pendingClaudeObservationBackfillsExistingRealSession() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        registry.noteResumeInitiated(
            sessionID: realSessionID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 333,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let record = try #require(registry.record(sessionID: realSessionID))
        #expect(registry.record(sessionID: pendingID) == nil)
        #expect(record.pid == 333)
        #expect(record.surfaceID == surfaceID)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == realSessionID)
    }

    @MainActor
    @Test func realClaudeHookRemovesPendingAliasWhenRealRecordAlreadyExists() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        var removedIDs: [String] = []
        registry.onRecordRemoved = { removedIDs.append($0.sessionID) }

        registry.noteResumeInitiated(
            sessionID: pendingID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )
        registry.noteResumeInitiated(
            sessionID: realSessionID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: realSessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: "/Users/example/.claude/projects/-Users-example-project/\(realSessionID).jsonl",
            cwd: "/Users/example/project",
            ppid: 555,
            receivedAt: Date(timeIntervalSince1970: 130)
        ))

        let record = try #require(registry.record(sessionID: realSessionID))
        #expect(registry.record(sessionID: pendingID) == nil)
        #expect(removedIDs == [pendingID])
        #expect(record.pid == 555)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == realSessionID)
    }

    @Test func mobileChatObserverStillDetectsDirectCodexFromRolloutFile() throws {
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

        var detailReadCount = 0
        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { _ in
                detailReadCount += 1
                return nil
            },
            codexRolloutPath: { pid in pid == 202 ? rolloutPath : nil }
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(detailReadCount == 0)
        #expect(session.sessionID == sessionID)
        #expect(session.agentKind == .codex)
        #expect(session.workspaceID == workspaceID.uuidString)
        #expect(session.surfaceID == surfaceID.uuidString)
        #expect(session.pid == 202)
        #expect(session.transcriptPath == rolloutPath)
    }

    @Test func mobileChatObserverIgnoresClaudeChildProcessWithInheritedEnvironment() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 303,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 300),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                guard pid == 303 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["node", "server.js"],
                    environment: [
                        "CMUX_AGENT_LAUNCH_KIND": "claude",
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                    ]
                )
            },
            codexRolloutPath: { _ in nil }
        )

        #expect(observed.isEmpty)
    }

    @Test func mobileChatLivenessRecognizesNodeHostedClaudeFromProcessDetails() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 505,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 500),
            includesProcessDetails: true
        )

        let livePID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            processArgumentsAndEnvironment: { pid in
                guard pid == 505 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "node",
                        "/Users/example/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js",
                    ],
                    environment: [
                        "CLAUDE_CODE_SESSION_ID": "24ec0052-450c-4914-b1dd-2ee80d4bc84b",
                    ]
                )
            }
        )

        #expect(livePID == 505)
    }

    @Test func mobileChatLivenessIgnoresClaudeChildProcessWithInheritedEnvironment() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 606,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 600),
            includesProcessDetails: true
        )

        let livePID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            processArgumentsAndEnvironment: { pid in
                guard pid == 606 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["node", "server.js"],
                    environment: [
                        "CMUX_AGENT_LAUNCH_KIND": "claude",
                        "CLAUDE_CODE_SESSION_ID": "24ec0052-450c-4914-b1dd-2ee80d4bc84b",
                    ]
                )
            }
        )

        #expect(livePID == nil)
    }

    @Test func mobileChatObserverSkipsUnambiguousNonAgentWithoutReadingDetails() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 404,
                    name: "server",
                    path: "/usr/local/bin/server",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 400),
            includesProcessDetails: true
        )

        var detailReadCount = 0
        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { _ in
                detailReadCount += 1
                return nil
            },
            codexRolloutPath: { _ in nil }
        )

        #expect(observed.isEmpty)
        #expect(detailReadCount == 0)
    }

    private func topProcess(
        pid: Int,
        name: String,
        path: String?,
        workspaceID: UUID,
        surfaceID: UUID,
        isForeground: Bool = true
    ) -> CmuxTopProcessInfo {
        let processGroupID = pid
        return CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: name,
            path: path,
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: surfaceID,
            cmuxAttributionReason: "test",
            processGroupID: processGroupID,
            terminalProcessGroupID: isForeground ? processGroupID : processGroupID + 1,
            cpuPercent: 0,
            residentBytes: 1,
            virtualBytes: 1,
            threadCount: 1
        )
    }

}
