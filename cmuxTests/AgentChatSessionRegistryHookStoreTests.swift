import Foundation
import Testing
import Darwin
import CMUXAgentLaunch
import CmuxFoundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryHookStoreTests {
    @Test func hookStoreFindsCanonicalSessionBeyondLegacyProjection() throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let stateDirectory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let targetSessionID = "chat-session-older-than-projection"
        let targetWorkspaceID = UUID().uuidString
        let targetSurfaceID = UUID().uuidString
        let targetTranscriptPath = "/tmp/\(targetSessionID).jsonl"
        let registry = CmuxAgentSessionRegistry(
            url: stateDirectory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        var records = try (0..<300).map { index in
            try canonicalHookRecord(
                provider: "claude",
                sessionID: String(format: "recent-%03d", index),
                workspaceID: UUID().uuidString,
                surfaceID: UUID().uuidString,
                transcriptPath: "/tmp/recent-\(index).jsonl",
                updatedAt: TimeInterval(1_000 + index)
            )
        }
        records.append(try canonicalHookRecord(
            provider: "claude",
            sessionID: targetSessionID,
            workspaceID: targetWorkspaceID,
            surfaceID: targetSurfaceID,
            transcriptPath: targetTranscriptPath,
            updatedAt: 1
        ))
        try registry.apply(provider: "claude", records: records)
        try writeCanonicalLegacyProjection(
            records: Array(records.prefix(256)),
            to: stateDirectory.appendingPathComponent("claude-hook-sessions.json")
        )

        let store = AgentChatHookSessionStore(homeDirectory: home)
        let entry = try #require(store.entry(agentSource: "claude", sessionID: targetSessionID))
        #expect(entry.workspaceID == targetWorkspaceID)
        #expect(entry.surfaceID == targetSurfaceID)
        #expect(entry.transcriptPath == targetTranscriptPath)
        #expect(store.entries(agentSource: "claude").count == 301)
    }

    @Test func hookStoreRetainsBoundedFlatLegacyFallback() throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let stateDirectory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let sessionID = "flat-chat-session"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: [
            sessionID: [
                "workspaceId": workspaceID,
                "surfaceId": surfaceID,
                "cwd": "/tmp/flat-chat",
                "updatedAt": 1.0,
            ],
        ], options: [.sortedKeys])
        try data.write(
            to: stateDirectory.appendingPathComponent("claude-hook-sessions.json"),
            options: .atomic
        )

        let entry = try #require(
            AgentChatHookSessionStore(homeDirectory: home)
                .entry(agentSource: "claude", sessionID: sessionID)
        )
        #expect(entry.workspaceID == workspaceID)
        #expect(entry.surfaceID == surfaceID)
        #expect(entry.workingDirectory == "/tmp/flat-chat")
    }

    @MainActor
    @Test func hookStoreSeedIsBoundedButExactHistoryRemainsAvailable() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let stateDirectory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let activeOldSessionID = "active-old-session"
        let exactOldSessionID = "inactive-old-session"
        let activeWorkspaceID = UUID().uuidString
        let activeSurfaceID = UUID().uuidString
        let registry = CmuxAgentSessionRegistry(
            url: stateDirectory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        var records = try (0..<700).map { index in
            try canonicalHookRecord(
                provider: "claude",
                sessionID: String(format: "recent-%03d", index),
                workspaceID: UUID().uuidString,
                surfaceID: UUID().uuidString,
                transcriptPath: "/tmp/recent-\(index).jsonl",
                updatedAt: TimeInterval(1_000 + index)
            )
        }
        records.append(try canonicalHookRecord(
            provider: "claude",
            sessionID: activeOldSessionID,
            workspaceID: activeWorkspaceID,
            surfaceID: activeSurfaceID,
            transcriptPath: "/tmp/active-old.jsonl",
            updatedAt: 1
        ))
        records.append(try canonicalHookRecord(
            provider: "claude",
            sessionID: exactOldSessionID,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            transcriptPath: "/tmp/inactive-old.jsonl",
            updatedAt: 2
        ))
        let slotJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": activeOldSessionID,
            "updatedAt": 1.0,
        ], options: [.sortedKeys])
        try registry.apply(
            provider: "claude",
            records: records,
            activeSlots: [
                .init(
                    provider: "claude",
                    scope: .surface,
                    scopeID: activeSurfaceID,
                    sessionID: activeOldSessionID,
                    updatedAt: 1,
                    json: slotJSON
                ),
            ]
        )

        let store = AgentChatHookSessionStore(homeDirectory: home)
        let seeded = store.entries(agentSource: "claude")
        #expect(seeded.count == AgentChatHookSessionStore.maximumSeedRecords)
        #expect(seeded.first?.sessionID == activeOldSessionID)
        #expect(seeded.contains { $0.sessionID == activeOldSessionID })
        #expect(!seeded.contains { $0.sessionID == exactOldSessionID })
        #expect(store.entry(agentSource: "claude", sessionID: exactOldSessionID) != nil)

        let chatRegistry = AgentChatSessionRegistry(hookStore: store)
        var appliedCount = 0
        chatRegistry.onRecordChanged = { _, _ in appliedCount += 1 }
        await chatRegistry.seedFromHookStores(agentSources: ["claude"])
        #expect(appliedCount == AgentChatHookSessionStore.maximumSeedRecords)
        #expect(chatRegistry.record(sessionID: activeOldSessionID) != nil)
        #expect(chatRegistry.record(sessionID: exactOldSessionID) == nil)
    }

    @Test func mobileChatObserverDetectsCmuxLaunchedOpaqueClaudeWrapper() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 121,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 115),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                guard pid == 121 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "node",
                        "/Users/example/.cmux-agent-wrapper/subrouter.js",
                    ],
                    environment: [
                        "CMUX_AGENT_LAUNCH_KIND": "claude",
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                        "CMUX_AGENT_LAUNCH_CWD": "/Users/example/opaque-project",
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
        #expect(session.pid == 121)
        #expect(session.workingDirectory == "/Users/example/opaque-project")
    }

    @Test func unidentifiedClaudeLivenessFallbackOnlyAppliesToUnresolvedPendingAlias() {
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let now = Date(timeIntervalSince1970: 120)
        var pending = AgentChatSessionRecord(
            sessionID: pendingID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: now,
            title: nil,
            pid: nil
        )

        #expect(AgentChatSessionRegistry.allowsUnidentifiedClaudeLivenessFallback(for: pending))

        pending.rememberHookStoreSessionID(realSessionID)
        #expect(!AgentChatSessionRegistry.allowsUnidentifiedClaudeLivenessFallback(for: pending))

        let real = AgentChatSessionRecord(
            sessionID: realSessionID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: now,
            title: nil,
            pid: nil
        )
        #expect(!AgentChatSessionRegistry.allowsUnidentifiedClaudeLivenessFallback(for: real))
    }

    @Test func mobileChatObserverRejectsArgvOnlyClaudeNeedleWithoutLaunchKind() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 122,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 116),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                guard pid == 122 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "node",
                        "/Users/example/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js",
                    ],
                    environment: [
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                        "CMUX_AGENT_LAUNCH_CWD": "/Users/example/not-authoritative",
                    ]
                )
            },
            codexRolloutPath: { _ in nil }
        )

        #expect(observed.isEmpty)
    }

    @MainActor
    @Test func hookStoreSeedKeepsStaleRealEntrySeparateFromPendingClaudeSession() async throws {
        let home = try temporaryHomeDirectory()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(realSessionID).jsonl"
        let stalePID = try #require(guaranteedDeadPID())
        try writeClaudeHookStore(
            home: home,
            sessionID: realSessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: transcriptPath,
            pid: stalePID
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )

        registry.noteResumeInitiated(
            sessionID: pendingID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )
        await registry.seedFromHookStores(agentSources: ["claude"])

        let pending = try #require(registry.record(sessionID: pendingID))
        let historical = try #require(registry.record(sessionID: realSessionID))
        #expect(pending.transcriptPath == nil)
        #expect(pending.hookStoreSessionID == nil)
        #expect(historical.transcriptPath == transcriptPath)
        #expect(historical.state == .ended)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == pendingID)
    }

    @MainActor
    @Test func hookStoreSeedMergesPidMatchedRealEntryIntoPendingClaudeSession() async throws {
        let home = try temporaryHomeDirectory()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(realSessionID).jsonl"
        let livePID = Int(ProcessInfo.processInfo.processIdentifier)
        try writeClaudeHookStore(
            home: home,
            sessionID: realSessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: transcriptPath,
            pid: livePID
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: livePID,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        await registry.seedFromHookStores(agentSources: ["claude"])

        let record = try #require(registry.record(sessionID: pendingID))
        #expect(registry.record(sessionID: realSessionID) == nil)
        #expect(record.hookStoreSessionID == realSessionID)
        #expect(record.transcriptPath == transcriptPath)
        #expect(record.pid == livePID)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == pendingID)
    }

    private func guaranteedDeadPID() -> Int? {
        for pid in 900_000..<1_000_000 {
            errno = 0
            if kill(pid_t(pid), 0) != 0, errno == ESRCH {
                return pid
            }
        }
        return nil
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
            processGroupID: pid,
            terminalProcessGroupID: pid,
            cpuPercent: 0,
            residentBytes: 1,
            virtualBytes: 1,
            threadCount: 1
        )
    }

    private func temporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeClaudeHookStore(
        home: URL,
        sessionID: String,
        workspaceID: String,
        surfaceID: String,
        transcriptPath: String,
        pid: Int
    ) throws {
        let directory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "sessions": [
                sessionID: [
                    "workspaceId": workspaceID,
                    "surfaceId": surfaceID,
                    "cwd": "/Users/example/project",
                    "transcriptPath": transcriptPath,
                    "pid": pid,
                    "updatedAt": 140.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("claude-hook-sessions.json"))
    }

    private func canonicalHookRecord(
        provider: String,
        sessionID: String,
        workspaceID: String,
        surfaceID: String,
        transcriptPath: String,
        updatedAt: TimeInterval
    ) throws -> CmuxAgentSessionRegistry.Record {
        let json = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionID,
            "workspaceId": workspaceID,
            "surfaceId": surfaceID,
            "cwd": "/tmp/project",
            "transcriptPath": transcriptPath,
            "pid": 999_999,
            "updatedAt": updatedAt,
        ], options: [.sortedKeys])
        return CmuxAgentSessionRegistry.Record(
            provider: provider,
            sessionID: sessionID,
            updatedAt: updatedAt,
            json: json
        )
    }

    private func writeCanonicalLegacyProjection(
        records: [CmuxAgentSessionRegistry.Record],
        to url: URL
    ) throws {
        var sessions: [String: Any] = [:]
        for record in records {
            sessions[record.sessionID] = try JSONSerialization.jsonObject(with: record.json)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessions": sessions,
        ], options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
