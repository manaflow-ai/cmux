import Foundation
import Testing
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryClaudeObservationTests {
    @Test func mobileChatObserverDetectsBunHostedClaudeFromProcessDetails() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "b6fbc8e1-2c4b-4e51-a2b8-fd17c2ad59f0"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 102,
                    name: "bun",
                    path: "/Users/example/.bun/bin/bun",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 102),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                guard pid == 102 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "bun",
                        "/Users/example/.bun/install/global/node_modules/@anthropic-ai/claude-code/cli.js",
                    ],
                    environment: [
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                        "CMUX_AGENT_LAUNCH_CWD": "/Users/example/bun-project",
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
        #expect(session.pid == 102)
        #expect(session.workingDirectory == "/Users/example/bun-project")
    }

    @Test func mobileChatObserverDetectsVersionNumberClaudeLauncherFromPath() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "5a2df315-4e1a-401f-9a46-b0601872bd5d"
        let launcherPath = "/Users/example/.local/share/claude/versions/2.1.140"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 103,
                    name: "2.1.140",
                    path: launcherPath,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 103),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                guard pid == 103 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        launcherPath,
                        "--resume",
                        sessionID,
                    ],
                    environment: [
                        "PWD": "/Users/example/versioned-project",
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
        #expect(session.pid == 103)
        #expect(session.workingDirectory == "/Users/example/versioned-project")
    }

    @Test func mobileChatObserverScopedScanIgnoresOtherSurfacesWithoutReadingDetails() throws {
        let workspaceID = UUID()
        let includedSurfaceID = UUID()
        let excludedSurfaceID = UUID()
        let includedSessionID = "1f55cb96-0741-41f8-bd3b-8b0cd18ae047"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 120,
                    name: "bun",
                    path: "/Users/example/.bun/bin/bun",
                    workspaceID: workspaceID,
                    surfaceID: includedSurfaceID
                ),
                topProcess(
                    pid: 121,
                    name: "bun",
                    path: "/Users/example/.bun/bin/bun",
                    workspaceID: workspaceID,
                    surfaceID: excludedSurfaceID
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 120),
            includesProcessDetails: true
        )
        var requestedDetailPIDs: [Int] = []

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            onlySurfaceIDs: [includedSurfaceID],
            processArgumentsAndEnvironment: { pid in
                requestedDetailPIDs.append(pid)
                guard pid == 120 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "bun",
                        "/Users/example/.bun/install/global/node_modules/@anthropic-ai/claude-code/cli.js",
                    ],
                    environment: [
                        "CLAUDE_CODE_SESSION_ID": includedSessionID,
                        "CMUX_AGENT_LAUNCH_CWD": "/Users/example/scoped-project",
                    ]
                )
            },
            codexRolloutPath: { _ in nil }
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == includedSessionID)
        #expect(session.surfaceID == includedSurfaceID.uuidString)
        #expect(requestedDetailPIDs == [120])
    }

    @Test func mobileChatObserverIgnoresBackgroundClaudeProcess() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 707,
                    name: "claude",
                    path: "/opt/homebrew/bin/claude",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    isForeground: false
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 700),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                guard pid == 707 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["claude"],
                    environment: [
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                        "CMUX_AGENT_LAUNCH_CWD": "/Users/example/project",
                    ]
                )
            },
            codexRolloutPath: { _ in nil }
        )

        #expect(observed.isEmpty)
    }

    @Test func mobileChatLivenessIgnoresBackgroundClaudeProcess() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 808,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    isForeground: false
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 800),
            includesProcessDetails: true
        )

        let livePID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            processArgumentsAndEnvironment: { pid in
                guard pid == 808 else { return nil }
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

        #expect(livePID == nil)
    }

    @Test func observationScopeOnlyReusesInFlightScansThatCoverRequestedSurfaces() {
        let surfaceA = UUID()
        let surfaceB = UUID()
        let all = AgentChatObservationScope(surfaceIDs: nil)
        let scanA = AgentChatObservationScope(surfaceIDs: [surfaceA])
        let scanAB = AgentChatObservationScope(surfaceIDs: [surfaceA, surfaceB])
        let requestA = AgentChatObservationScope(surfaceIDs: [surfaceA])
        let requestB = AgentChatObservationScope(surfaceIDs: [surfaceB])

        #expect(all.covers(requestA))
        #expect(scanAB.covers(requestA))
        #expect(scanAB.covers(requestB))
        #expect(scanA.covers(requestA))
        #expect(!scanA.covers(requestB))
        #expect(!scanA.covers(all))
        #expect(!requestA.covers(scanAB))
    }

    @MainActor
    @Test func observationWaitTimeoutRemovesWaiterWithoutDrainingSlowTask() async {
        let clock = ContinuousClock()
        let slowTask = Task<Void, Never> {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {}
        }
        defer { slowTask.cancel() }
        let registry = AgentChatSessionRegistry()
        let observationID = UUID()
        registry.observeInFlight = AgentChatObservationInFlight(
            id: observationID,
            scope: .all,
            task: slowTask
        )
        let handle = AgentChatObservationHandle(id: observationID, task: slowTask)

        let start = clock.now
        let completed = await registry.waitForObservation(
            handle,
            upTo: .milliseconds(50)
        )
        let elapsed = start.duration(to: clock.now)

        #expect(!completed)
        #expect(elapsed < .seconds(1))
        #expect(registry.observeInFlight?.waiters.isEmpty == true)
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
