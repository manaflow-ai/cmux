import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryLifecycleTests {
    @MainActor
    @Test func hookStoreSeedDoesNotRestoreStalePIDOntoExistingLiveRecord() async throws {
        let home = try temporaryHomeDirectory()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let (staleWorkspaceID, staleSurfaceID) = (UUID().uuidString, UUID().uuidString)
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(sessionID).jsonl"
        try writeClaudeHookStore(
            home: home,
            sessionID: sessionID,
            workspaceID: staleWorkspaceID,
            surfaceID: staleSurfaceID,
            transcriptPath: transcriptPath,
            pid: 444
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )

        registry.noteResumeInitiated(
            sessionID: sessionID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )
        await registry.seedFromHookStores(agentSources: ["claude"])

        let record = try #require(registry.record(sessionID: sessionID))
        #expect(record.workspaceID == workspaceID)
        #expect(record.surfaceID == surfaceID)
        #expect(record.transcriptPath == transcriptPath)
        #expect(record.pid == nil)
        #expect(record.state == .idle)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == sessionID)
    }

    @MainActor
    @Test func endedPendingClaudeObservationRevivesForNewIdleProcess() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let record = try #require(registry.record(sessionID: pendingID))
        #expect(record.state == .idle)
        #expect(record.pid == 222)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == pendingID)
    }

    @MainActor
    @Test func transcriptBackedEndedPendingClaudeIsPreservedWhenNewIdleProcessAppears() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let nextPendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID, pid: 222)
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/session.jsonl"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.transcriptPath = transcriptPath
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let ended = try #require(registry.record(sessionID: pendingID))
        let live = try #require(registry.record(sessionID: nextPendingID))
        #expect(ended.state == .ended)
        #expect(ended.transcriptPath == transcriptPath)
        #expect(live.state == .idle)
        #expect(live.pid == 222)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == nextPendingID)
    }

    @MainActor
    @Test func stalePendingClaudeObservationDoesNotCreateNewLiveAlias() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let nextPendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID, pid: 222)
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/session.jsonl"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil,
                sampledAt: Date(timeIntervalSince1970: 100)
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.transcriptPath = transcriptPath
            record.state = .ended
        }
        let endedAt = try #require(registry.record(sessionID: pendingID)?.endedAt)

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil,
                sampledAt: endedAt.addingTimeInterval(-1)
            ),
        ])

        let ended = try #require(registry.record(sessionID: pendingID))
        #expect(ended.state == .ended)
        #expect(ended.pid == 111)
        #expect(registry.record(sessionID: nextPendingID) == nil)
        #expect(registry.liveSession(surfaceID: surfaceID) == nil)
    }

    @MainActor
    @Test func hookBackedEndedPendingClaudeIsPreservedWhenNewIdleProcessAppears() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let nextPendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID, pid: 222)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.rememberHookStoreSessionID(realSessionID)
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let ended = try #require(registry.record(sessionID: pendingID))
        let live = try #require(registry.record(sessionID: nextPendingID))
        #expect(ended.state == .ended)
        #expect(ended.hookStoreSessionID == realSessionID)
        #expect(live.state == .idle)
        #expect(live.pid == 222)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == nextPendingID)
    }

    @MainActor
    @Test func endedCodexObservationRevivesRealSessionID() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: "/Users/example/.codex/sessions/rollout-\(sessionID).jsonl"
            ),
        ])
        registry.update(sessionID: sessionID) { record in
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let record = try #require(registry.record(sessionID: sessionID))
        #expect(record.state == .idle)
        #expect(record.pid == 222)
        #expect(record.transcriptPath == "/Users/example/.codex/sessions/rollout-\(sessionID).jsonl")
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == sessionID)
    }

    @MainActor
    @Test func staleProcessObservationDoesNotReviveEndedSession() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: "/Users/example/.codex/sessions/rollout-\(sessionID).jsonl",
                sampledAt: Date(timeIntervalSince1970: 100)
            ),
        ])
        registry.update(sessionID: sessionID) { record in
            record.state = .ended
        }
        let endedAt = try #require(registry.record(sessionID: sessionID)?.endedAt)

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil,
                sampledAt: endedAt.addingTimeInterval(-1)
            ),
        ])

        let record = try #require(registry.record(sessionID: sessionID))
        #expect(record.state == .ended)
        #expect(record.pid == 111)
        #expect(registry.liveSession(surfaceID: surfaceID) == nil)
    }

    @MainActor
    @Test func pendingClaudeAliasRefreshesFromRealHookStoreSessionID() async throws {
        let home = try temporaryHomeDirectory()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(realSessionID).jsonl"
        try writeClaudeHookStore(
            home: home,
            sessionID: realSessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: transcriptPath,
            pid: 222
        )
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))

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
            transcriptPath: nil,
            cwd: "/Users/example/project",
            ppid: 333,
            receivedAt: Date(timeIntervalSince1970: 150)
        ))

        let refreshed = try #require(await registry.refreshBindingsFromHookStore(sessionID: pendingID))
        #expect(refreshed.transcriptPath == transcriptPath)
        #expect(refreshed.pid == 333)
    }

    @MainActor
    @Test func endedSessionWithMissingTranscriptIsNotListableForMobileChat() throws {
        let home = try temporaryHomeDirectory()
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        let record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: transcriptURL.path,
            state: .ended,
            lastActivityAt: Date(),
            title: nil,
            pid: nil
        )

        #expect(!service.hasBoundedReadableTranscript(record))

        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        #expect(service.hasBoundedReadableTranscript(record))
        _ = service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID, hookEventName: .sessionEnd, source: "claude",
            workspaceId: record.workspaceID, surfaceId: record.surfaceID,
            transcriptPath: transcriptURL.path, cwd: "/Users/example/project", ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 250)
        ))
        let cachedRecord = try #require(service.sessionRecord(sessionID: sessionID))
        #expect(cachedRecord.state == .ended)
        #expect(service.shouldListEndedSession(cachedRecord))
    }

    @MainActor
    @Test func endedCodexSessionListabilityKeepsFallbackRowsWithoutScanningHistory() throws {
        let home = try temporaryHomeDirectory()
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".codex/sessions/2026/06/30", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-30T00-00-00-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .codex,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .ended,
            lastActivityAt: Date(),
            title: nil,
            pid: nil
        )

        #expect(!service.hasBoundedReadableTranscript(record))
        #expect(service.shouldListEndedSession(record))
    }

    @MainActor
    @Test func pendingClaudeAliasUsesRealHookSessionIDForFallbackTranscript() throws {
        let home = try temporaryHomeDirectory()
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(realSessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)
        var record = AgentChatSessionRecord(
            sessionID: pendingID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .ended,
            lastActivityAt: Date(),
            title: nil,
            pid: nil
        )
        record.rememberHookStoreSessionID(realSessionID)

        #expect(service.hasBoundedReadableTranscript(record))
    }

    @MainActor
    @Test func recentAgentFilesAreScopedDeduplicatedAndSortedFromTranscriptHistory() async throws {
        let home = try temporaryHomeDirectory()
        let project = home.appendingPathComponent("project", isDirectory: true)
        let transcript = home.appendingPathComponent("session.jsonl")
        let workspaceID = UUID()
        let sessionID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let appFile = project.appendingPathComponent("Sources/App.swift").path
        let guideFile = project.appendingPathComponent("Docs/Guide.md").path
        let lines = [
            try claudeFileToolLine(
                filePath: appFile,
                toolName: "Edit",
                timestamp: "2026-07-09T10:00:00.000Z"
            ),
            try claudeFileToolLine(
                filePath: home.appendingPathComponent("outside.txt").path,
                toolName: "Write",
                timestamp: "2026-07-09T10:30:00.000Z"
            ),
            try claudeFileToolLine(
                filePath: guideFile,
                toolName: "Edit",
                timestamp: "2026-07-09T10:45:00.000Z"
            ),
            try claudeFileToolLine(
                filePath: appFile,
                toolName: "Write",
                timestamp: "2026-07-09T11:00:00.000Z"
            ),
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID.uuidString,
            surfaceId: surfaceID,
            transcriptPath: transcript.path,
            cwd: project.path,
            receivedAt: Date(timeIntervalSince1970: 100)
        ))
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionEnd,
            source: "claude",
            workspaceId: workspaceID.uuidString,
            surfaceId: surfaceID,
            transcriptPath: transcript.path,
            cwd: project.path,
            receivedAt: Date(timeIntervalSince1970: 110)
        ))

        let files = await service.recentFiles(
            in: AgentRecentFileScope(workspaceID: workspaceID, rootDirectory: project.path),
            limit: 10
        )

        #expect(files.count == 2)
        #expect(files.map(\.path) == [appFile, guideFile])
        #expect(files.map(\.relativePath) == ["Sources/App.swift", "Docs/Guide.md"])
        #expect(files.first?.agentKind == .claude)
        #expect(files.first?.operation == .write)
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

    private func claudeFileToolLine(filePath: String, toolName: String, timestamp: String) throws -> String {
        let input: [String: Any]
        if toolName == "Write" {
            input = ["file_path": filePath, "content": "new content"]
        } else {
            input = ["file_path": filePath, "old_string": "old", "new_string": "new"]
        }
        let payload: [String: Any] = [
            "parentUuid": "user",
            "isSidechain": false,
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [[
                    "type": "tool_use",
                    "id": UUID().uuidString,
                    "name": toolName,
                    "input": input,
                ]],
            ],
            "uuid": UUID().uuidString,
            "timestamp": timestamp,
            "sessionId": UUID().uuidString,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
